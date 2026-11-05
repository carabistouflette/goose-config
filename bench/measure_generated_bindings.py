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

NAMES = ('construct','environment','cli')
SOURCES = ('config.goose','toml.goose','vendor.goose','json_layer.goose','bindings.goose','reload.goose','typed.goose','GOOSE_REVISION','bench/generated_bindings.goose','bench/worker_settings.goose','schemas/worker.json')

def sha(data): return hashlib.sha256(data).hexdigest()

class RunFailure(RuntimeError):
    def __init__(self, command, out, err, returncode, timed_out=False):
        super().__init__('process timed out' if timed_out else 'process failed')
        self.command=list(map(str,command)); self.stdout=out; self.stderr=err
        self.returncode=returncode; self.timed_out=timed_out

def run(command, *, env=None, cwd=None, timeout=120):
    process = subprocess.Popen(list(map(str,command)), env=env, cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        out,err=process.communicate()
        raise RunFailure(command,out,err,process.returncode,True) from None
    except BaseException:
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        process.communicate()
        raise
    if process.returncode: raise RunFailure(command,out,err,process.returncode)
    return out, err

def parse(output, count):
    rows=parse_fixtures(output,NAMES)
    keys=('worker.name','worker.prefix','worker.queues','worker.min_bytes','worker.max_bytes','worker.enabled')
    env=('GOOSE_WORKER_NAME','GOOSE_WORKER_PREFIX','GOOSE_WORKER_QUEUES','GOOSE_WORKER_MIN_BYTES','GOOSE_WORKER_MAX_BYTES','GOOSE_WORKER_ENABLED')
    cli=('name','prefix','queue','min-bytes','max-bytes','enabled')
    expected=7*sum(len(keys[(i*5)%6])+len(env[(i*5)%6])+1+len(cli[(i*5)%6]) for i in range(count))
    for name,row in rows.items():
        if row['checksum'] != (expected if name=='construct' else 7*count*9):raise ValueError('wrong binding checksum')
    return rows

def failure_record(context, error, redactions):
    result=dict(context or {})
    result.update(exception_type=type(error).__name__,exception_message=str(error))
    if isinstance(error,RunFailure):
        result.update(argv=error.command,raw_stdout=error.stdout,raw_stderr=error.stderr,
                      returncode=error.returncode,timed_out=error.timed_out)
    def clean(value):
        if isinstance(value,str):
            for source,replacement in sorted(redactions,key=lambda pair:len(pair[0]),reverse=True):
                value=value.replace(source,replacement)
        elif isinstance(value,list):return [clean(item) for item in value]
        elif isinstance(value,dict):return {key:clean(item) for key,item in value.items()}
        return value
    return clean(result)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--goose',type=Path,required=True);p.add_argument('--revision',default='HEAD')
    p.add_argument('--cpu',type=int,required=True);p.add_argument('--iterations',type=int,default=1000)
    p.add_argument('--rounds',type=int,default=9);p.add_argument('--seed',type=int,default=606)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--disassembly-output',type=Path)
    a=p.parse_args()
    if not 1<=a.iterations<=100000 or not 1<=a.rounds<=20:p.error('iterations1..100000; rounds1..20')
    if a.cpu not in os.sched_getaffinity(0):p.error('CPU outside affinity')
    if a.output.exists() or a.output.is_symlink():p.error('choose a fresh output path; preserve previous records')
    if a.disassembly_output:
        if a.disassembly_output.exists() or a.disassembly_output.is_symlink():p.error('choose a fresh disassembly path')
        if a.disassembly_output.resolve()==a.output.resolve():p.error('JSON and disassembly paths must differ')
    os.sched_setaffinity(0,{a.cpu}); compiler=a.goose.resolve(strict=True)
    revision=run(['git','rev-parse','--verify','--end-of-options',f'{a.revision}^{{commit}}'],cwd=ROOT)[0].strip()
    data={name:subprocess.check_output(['git','show',f'{revision}:{name}'],cwd=ROOT,timeout=30) for name in SOURCES}
    pin=data['GOOSE_REVISION'].decode().strip(); version=run([compiler,'--version'])[0].strip()
    if not version.startswith(f'goose {pin[:7]} '):p.error('compiler pin mismatch')
    gcc=Path(shutil.which('gcc')).resolve(strict=True)
    inputs={'gcc':gcc,'bench/measure.py':ROOT/'bench/measure.py','bench/measure_generated_bindings.py':Path(__file__).resolve()}
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
            'limitations':['Shared host; no exclusive isolation or control correction.',
                           'Generated fixed arrays compared with prior fixed manual literals; exact metadata bytes checked before timing.',
                           'Construction may be folded/hoisted; throughput is not allocation latency.',
                           'Environment/CLI include schema initialization and controlled application, not process startup or native getenv.',
                           'Three fixed-order cases per process; shuffled callers; reference A/B use identical binary/argv.',
                           'Full final values/lists/sources checked outside timer; no RSS/allocation or universal speed claim.'],
            'warmup':'Counts1/2/3 per caller preflighted; first timed batch retained.','preflights':[],'measurements':[]}
    pending=None; work=None
    try:
        with tempfile.TemporaryDirectory(prefix='run-',dir=parent) as tmp:
            work=Path(tmp)
            for name,value in data.items():
                path=work/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(value)
            env={key:os.environ[key] for key in ('PATH','HOME') if key in os.environ}
            env.update(GOOSE_HOME=str(work/'goose-home'),LANG='C',TZ='UTC')
            binary=work/'typed-benchmark'
            command=[compiler,'build',work/'bench/generated_bindings.goose','--cc','gcc','-O2','-o',binary]
            pending={'phase':'build','argv':list(map(str,command))}
            run(command,env=env,timeout=300);pending=None
            record['binary_sha256']=sha(binary.read_bytes())
            if a.disassembly_output:
                assembly=run(['objdump','-d',binary])[0];a.disassembly_output.parent.mkdir(parents=True,exist_ok=True);a.disassembly_output.write_text(assembly)
                record['native_disassembly_sha256']=sha(assembly.encode())
            for count in (1,2,3):
                for caller in ('generated','reference'):
                    command=[binary,count,caller];pending={'phase':'preflight','count':count,'caller':caller,'argv':list(map(str,command))}
                    out,err=run(command,env=env);pending.update(raw_stdout=out,raw_stderr=err)
                    if err:raise ValueError('preflight wrote stderr')
                    record['preflights'].append({'count':count,'caller':caller,'raw_stdout':out,'fixtures':parse(out,count)})
                    pending=None
            rng=random.Random(a.seed);record['utc_start']=datetime.now(timezone.utc).isoformat()
            for round_id in range(a.rounds):
                order=['generated','reference-A','reference-B'];rng.shuffle(order)
                for label in order:
                    command=[binary,a.iterations,'generated' if label=='generated' else 'reference']
                    pending={'phase':'measurement','round':round_id,'caller':label,'argv':list(map(str,command))}
                    out,err=run(command,env=env);pending.update(raw_stdout=out,raw_stderr=err)
                    if err:raise ValueError('measured process wrote stderr')
                    record['measurements'].append({'round':round_id,'caller':label,'raw_stdout':out,'fixtures':parse(out,a.iterations)})
                    pending=None
                    write_record(a.output,record)
            if record['binary_sha256']!=sha(binary.read_bytes()):raise ValueError('binary changed')
        if compiler_hash!=sha(compiler.read_bytes()) or hashes!={name:sha(path.read_bytes()) for name,path in inputs.items()}:raise ValueError('toolchain changed')
        record['median_of_run_medians_ns']={caller:{name:statistics.median(row['fixtures'][name]['median_ns'] for row in record['measurements'] if row['caller']==caller) for name in NAMES} for caller in ('generated','reference-A','reference-B')}
        record['completed']=True
    except BaseException as error:
        paths=[(str(compiler),'<goose>'),(str(ROOT),'<repository>')]
        if work is not None:paths.append((str(work),'<snapshot>'))
        record['failure']=failure_record(pending,error,paths)
        raise
    finally:
        record['recorded_utc']=datetime.now(timezone.utc).isoformat();write_record(a.output,record)
    print(json.dumps(record['median_of_run_medians_ns'],indent=2))

if __name__=='__main__':main()
