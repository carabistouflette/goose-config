#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Measure frozen typed loads/reference loads and identical-binary controls."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import signal
import statistics
import subprocess
import tempfile
from measure import ROOT, parse_fixtures, write_record

NAMES = ('load-small','load-owned','cold-owned','optional-removal','refresh-owned',
         'reject-validator','reject-schema','application-read')
SOURCES = ('config.goose','toml.goose','vendor.goose','json_layer.goose','bindings.goose',
           'reload.goose','typed.goose','GOOSE_REVISION','bench/typed_settings.goose',
           'bench/typed_reference.goose','bench/typed_fixture.goose','schemas/typed-test.json')

def sha(data): return hashlib.sha256(data).hexdigest()

def run(command, *, env=None, cwd=None, timeout=120):
    process = subprocess.Popen(list(map(str,command)), env=env, cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = process.communicate(timeout=timeout)
    except BaseException:
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        process.communicate()
        raise
    if process.returncode: raise subprocess.CalledProcessError(process.returncode,command,out,err)
    return out, err

def digest(first, large=False, optional=False):
    # Independent fixed-fixture oracle, including every scalar/list family.
    if optional: return 7+len('snapshot-b')
    label = (1024 if first else 1001) if large else (5 if first else 7)
    tag = (3000 if first else 2991) if large else (3 if first else 4)
    return (label+len('snapshot-a')+(1 if first else 4)+(5 if first else 10)+
            (19 if first else 17)+(250000000 if first else 1000000000)+tag+
            (6 if first else 0)+len('snapshot-a')+(2 if first else 3)+(10 if first else 7)+52+
            (1000000000 if first else 750000000))

def parse(output, count):
    rows = parse_fixtures(output,NAMES); total=7*count; first=(total+1)//2; second=total//2
    for name,row in rows.items():
        if name=='reject-validator': expected=total*len('policy rejected')
        elif name=='reject-schema': expected=total*len("config: unknown key [key='delays', source='']")
        elif name=='application-read': expected=first+second*250000000
        else:
            large=name in ('load-owned','cold-owned','refresh-owned')
            expected=first*digest(True,large)+second*digest(False,large,name=='optional-removal')
        if row['checksum']!=expected: raise ValueError('incorrect fixture checksum: '+name)
    return rows

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--goose',type=Path,required=True);p.add_argument('--revision',default='HEAD')
    p.add_argument('--cpu',type=int,required=True);p.add_argument('--iterations',type=int,default=1000)
    p.add_argument('--rounds',type=int,default=9);p.add_argument('--seed',type=int,default=606)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--disassembly-output',type=Path)
    a=p.parse_args()
    if not 1<=a.iterations<=100000 or not 1<=a.rounds<=20:p.error('iterations1..100000; rounds1..20')
    if a.cpu not in os.sched_getaffinity(0):p.error('CPU outside affinity')
    if a.output.exists():p.error('choose a fresh output path; preserve previous records')
    os.sched_setaffinity(0,{a.cpu}); compiler=a.goose.resolve(strict=True)
    revision=run(['git','rev-parse','--verify','--end-of-options',f'{a.revision}^{{commit}}'],cwd=ROOT)[0].strip()
    data={name:subprocess.check_output(['git','show',f'{revision}:{name}'],cwd=ROOT,timeout=30) for name in SOURCES}
    pin=data['GOOSE_REVISION'].decode().strip(); version=run([compiler,'--version'])[0].strip()
    if not version.startswith(f'goose {pin[:7]} '):p.error('compiler pin mismatch')
    gcc=Path(shutil.which('gcc')).resolve(strict=True)
    inputs={'gcc':gcc,'bench/measure.py':ROOT/'bench/measure.py','bench/measure_typed.py':Path(__file__).resolve()}
    for name in ('cc1','as','ld'):
        tool=run([gcc,'-print-prog-name='+name])[0].strip()
        inputs[name]=Path(shutil.which(tool) or tool).resolve(strict=True)
    for path in [compiler.parent.parent/'src/runtime_inline.h',*sorted((compiler.parent.parent/'stdlib').rglob('*.goose')),*sorted((compiler.parent.parent/'src/runtime').glob('*.h'))]:
        inputs[str(path.relative_to(compiler.parent.parent))]=path
    hashes={name:sha(path.read_bytes()) for name,path in inputs.items()}; compiler_hash=sha(compiler.read_bytes())
    cpu=next((line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),'unknown')
    parent=ROOT/'.build/typed-measure';parent.mkdir(parents=True,exist_ok=True)
    record={'completed':False,'smoke_only':a.iterations<=2,'revision':revision,'compiler_revision':pin,
            'compiler_version':version,'compiler_sha256':compiler_hash,'source_sha256':{name:sha(value) for name,value in data.items()},
            'toolchain_input_sha256':hashes,'platform':platform.platform(),'cpu':cpu,'cpu_affinity':sorted(os.sched_getaffinity(0)),
            'gcc':run([gcc,'--version'])[0].splitlines()[0],'flags':'GCC -O2','iterations':a.iterations,'rounds':a.rounds,'seed':a.seed,
            'limitations':['Shared host, no exclusive isolation or control correction.',
                           'Fixed case order within each process; caller process order reproducibly shuffled.',
                           'Reference uses metadata preflight before staging; generated loader interleaves it.',
                           'Reference fuses numeric-list check/copy; generated code uses separate loops.',
                           'Cold means fresh logical destination in a warmed process, not cold pages or startup.',
                           'Reads measure optimized workload throughput, not nominal per-read latency.',
                           'Ten-kind fixtures only, not wide-schema or compile-time performance; no RSS/allocation claim.'],
            'warmup':'Counts1/2/3 per caller preflighted; first timed batch retained.','preflights':[],'measurements':[]}
    try:
        with tempfile.TemporaryDirectory(prefix='run-',dir=parent) as tmp:
            work=Path(tmp)
            for name,value in data.items():
                path=work/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(value)
            env={key:os.environ[key] for key in ('PATH','HOME') if key in os.environ}
            env.update(GOOSE_HOME=str(work/'goose-home'),LANG='C',TZ='UTC')
            binary=work/'typed-benchmark'
            run([compiler,'build',work/'bench/typed_settings.goose','--cc','gcc','-O2','-o',binary],env=env,timeout=300)
            record['binary_sha256']=sha(binary.read_bytes())
            if a.disassembly_output:
                assembly=run(['objdump','-d',binary])[0];a.disassembly_output.parent.mkdir(parents=True,exist_ok=True);a.disassembly_output.write_text(assembly)
                record['native_disassembly_sha256']=sha(assembly.encode())
            for count in (1,2,3):
                for caller in ('generated','reference'):
                    out,err=run([binary,count,caller],env=env)
                    if err:raise ValueError('preflight wrote stderr')
                    record['preflights'].append({'count':count,'caller':caller,'raw_stdout':out,'fixtures':parse(out,count)})
            rng=random.Random(a.seed);record['utc_start']=datetime.now(timezone.utc).isoformat()
            for round_id in range(a.rounds):
                order=['generated','reference-A','reference-B'];rng.shuffle(order)
                for label in order:
                    out,err=run([binary,a.iterations,'generated' if label=='generated' else 'reference'],env=env)
                    if err:raise ValueError('measured process wrote stderr')
                    record['measurements'].append({'round':round_id,'caller':label,'raw_stdout':out,'fixtures':parse(out,a.iterations)})
                    write_record(a.output,record)
            if record['binary_sha256']!=sha(binary.read_bytes()):raise ValueError('binary changed')
        if compiler_hash!=sha(compiler.read_bytes()) or hashes!={name:sha(path.read_bytes()) for name,path in inputs.items()}:raise ValueError('toolchain changed')
        record['median_of_run_medians_ns']={caller:{name:statistics.median(row['fixtures'][name]['median_ns'] for row in record['measurements'] if row['caller']==caller) for name in NAMES} for caller in ('generated','reference-A','reference-B')}
        record['completed']=True
    finally:
        record['recorded_utc']=datetime.now(timezone.utc).isoformat();write_record(a.output,record)
    print(json.dumps(record['median_of_run_medians_ns'],indent=2))

if __name__=='__main__':main()
