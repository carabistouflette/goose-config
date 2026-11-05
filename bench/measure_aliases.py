#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Record frozen alias lookups with full raw samples and input identities."""
import argparse
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import tempfile
from measure import ROOT, parse_fixtures, write_record

NAMES = tuple(f'{mode}-{size}{suffix}' for size in (8,256) for suffix in ('','-long') for mode in ('canonical','alias','missing'))
MODULES = ('config.goose','toml.goose','vendor.goose','json_layer.goose','bindings.goose','reload.goose')
def sha(data): return hashlib.sha256(data).hexdigest()
def run(command, **kwargs):
    p = subprocess.run(list(map(str,command)),capture_output=True,text=True,check=True,timeout=180,**kwargs)
    return p.stdout

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--goose',type=Path,required=True); p.add_argument('--revision',default='HEAD')
    p.add_argument('--iterations',type=int,default=10000); p.add_argument('--runs',type=int,default=9)
    p.add_argument('--disassembly-output',type=Path); p.add_argument('--cpu',type=int,required=True); p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    if not 1<=a.iterations<=100000 or not 1<=a.runs<=20: p.error('iterations1..100000; runs1..20')
    if a.cpu not in os.sched_getaffinity(0):p.error('CPU outside affinity')
    os.sched_setaffinity(0,{a.cpu})
    compiler=a.goose.resolve(strict=True)
    rev=run(['git','rev-parse','--verify','--end-of-options',f'{a.revision}^{{commit}}'],cwd=ROOT).strip()
    pin=run(['git','show',f'{rev}:GOOSE_REVISION'],cwd=ROOT).strip();version=run([compiler,'--version']).strip()
    if not version.startswith(f'goose {pin[:7]} '):p.error('compiler pin mismatch')
    gcc=Path(shutil.which('gcc')).resolve(strict=True)
    inputs=[gcc, ROOT/'bench/measure.py', compiler.parent.parent/'src/runtime_inline.h']
    inputs+=sorted((compiler.parent.parent/'stdlib').rglob('*.goose'))
    inputs+=sorted((compiler.parent.parent/'src/runtime').glob('*.h'))
    identity_inputs={str(i):sha(i.read_bytes()) for i in inputs}
    cpu=next((line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')), 'unknown')
    parent=ROOT/'.build/alias-measure'; parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='run-',dir=parent) as tmp:
        work=Path(tmp);(work/'bench').mkdir()
        hashes={}
        for name in (*MODULES,'bench/aliases.goose'):
            data=subprocess.check_output(['git','show',f'{rev}:{name}'],cwd=ROOT,timeout=30)
            (work/name).write_bytes(data);hashes[name]=sha(data)
        env={key:os.environ[key] for key in ('PATH','HOME') if key in os.environ}
        env.update(GOOSE_HOME=str(work/'goose-home'),LANG='C',TZ='UTC')
        binary=work/'benchmark'
        run([compiler,'build',work/'bench/aliases.goose','--cc','gcc','-O2','-o',binary],env=env)
        assembly_hash=None
        if a.disassembly_output is not None:
            assembly=run(['objdump','-d',binary]);a.disassembly_output.parent.mkdir(parents=True,exist_ok=True);a.disassembly_output.write_text(assembly);assembly_hash=sha(assembly.encode())
        identities={'compiler':sha(compiler.read_bytes()),'benchmark':sha(binary.read_bytes())}
        measurements=[]; reference=None
        for i in range(a.runs):
            r=subprocess.run([str(binary),str(a.iterations)],env=env,capture_output=True,text=True,timeout=120,check=True)
            if r.stderr:raise ValueError(r.stderr)
            fixtures=parse_fixtures(r.stdout,NAMES)
            sums={key:row['checksum'] for key,row in fixtures.items()}
            for key,checksum in sums.items():
                if not key.startswith('missing-'):
                    size=int(key.split('-')[1]); expected=7*sum((i*73)%size+1 for i in range(a.iterations))
                    if checksum!=expected:raise ValueError('wrong lookup checksum')
            if reference is not None and sums!=reference:raise ValueError('unstable checksums')
            reference=sums
            measurements.append({'run':i,'raw_stdout':r.stdout,'fixtures':fixtures})
        if identity_inputs!={str(i):sha(i.read_bytes()) for i in inputs}:raise ValueError('toolchain input changed')
        if identities!={'compiler':sha(compiler.read_bytes()),'benchmark':sha(binary.read_bytes())}:raise ValueError('binary changed')
        record={'recorded_utc':datetime.now(timezone.utc).isoformat(),'revision':rev,'compiler_revision':pin,'compiler_version':version,'platform':platform.platform(),'cpu':cpu,'warmup':'none; first batch included','native_disassembly_sha256':assembly_hash,'toolchain_input_sha256':{str(i.relative_to(compiler.parent.parent)) if i.is_relative_to(compiler.parent.parent) else ('gcc' if i==gcc else 'bench/measure.py'):v for i,v in ((Path(k),v) for k,v in identity_inputs.items())},'cpu_affinity':sorted(os.sched_getaffinity(0)),'gcc':run(['gcc','--version']).splitlines()[0],'flags':'GCC -O2','iterations':a.iterations,'runs':a.runs,'source_sha256':hashes,'binary_sha256':identities,'recorder_sha256':sha(Path(__file__).read_bytes()),'limitations':['Shared host; no isolation or causal ranking.','One caller; fixed fixture order, setup outside timed loops.','Canonical-hit cases still have aliases configured; use paired core results for ordinary stores.','Missing-key cases include owned diagnostics. No memory or initialization timings.'],'measurements':measurements,'median_of_run_medians_ns':{key:statistics.median(r['fixtures'][key]['median_ns'] for r in measurements) for key in NAMES}}
        write_record(a.output,record)
        print(record['median_of_run_medians_ns'])
if __name__=='__main__':main()
