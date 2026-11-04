#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Reproduce scalar fallback A/A and A/B controls with immutable local snapshots.

Run from the goose-config repository. Builds default to CPU6; timings default to CPU7; both are configurable.
No checkout modifications, governor changes, or exclusive-isolation claims.
"""
import argparse, atexit, hashlib, importlib.util, json, os, platform, re, signal, statistics, subprocess, time
from pathlib import Path
location = argparse.ArgumentParser(add_help=False)
location.add_argument('--root', type=Path, default=Path.cwd())
location.add_argument('--workdir', type=Path, default=Path('.build/fallback-reproduction'))
location.add_argument('--goose', type=Path)
location.add_argument('--cpu', type=int, default=7)
location.add_argument('--build-cpu', type=int, default=6)
location.add_argument('--before-ref', default='53a68329332d20f61f5f4e9accedd651de8094f5')
location.add_argument('--after-ref', default='3ba1ecfaff9d640a8bad2cb76fd8c0b0e213ba9d')
location.add_argument('--harness-ref', default='3ba1ecfaff9d640a8bad2cb76fd8c0b0e213ba9d')
settings, _ = location.parse_known_args()
ROOT = settings.root.resolve()
HERE = settings.workdir.resolve()
HERE.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('measure', ROOT/'bench/measure.py')
measure = importlib.util.module_from_spec(spec); spec.loader.exec_module(measure)
FALLBACK = ('update-text-resize-large','update-text-list-large','update-two-text-large')
def cmd(argv, **kw):
    timeout=kw.pop('timeout',120)
    process=subprocess.Popen([str(a) for a in argv],stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE,text=True,start_new_session=True,**kw)
    try:
        stdout,stderr=process.communicate(timeout=timeout)
    except BaseException:
        try: os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError: pass
        process.communicate()
        raise
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode,argv,stdout,stderr)
    return subprocess.CompletedProcess(argv,process.returncode,stdout,stderr)
def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def portable(value):
    if isinstance(value, dict): return {k:portable(v) for k,v in value.items()}
    if isinstance(value, list): return [portable(v) for v in value]
    if isinstance(value, str):
        return value.replace(str(HERE), '<ARTIFACTS>').replace(str(ROOT), '<WORKSPACE>')
    return value
def dump(path, data): measure.write_record(path, portable(data))
def prepare():
    if settings.goose is None: raise SystemExit('--goose is required for --prepare')
    if any(path.name != '.active.lock' for path in HERE.iterdir()):
        raise SystemExit('preparation requires an empty workdir; choose a new --workdir')
    compiler = settings.goose.resolve()
    harness_revision=cmd(['git','rev-parse','--verify',f'{settings.harness_ref}^{{commit}}'],cwd=ROOT).stdout.strip()
    harness=cmd(['git','show',f'{harness_revision}:bench/updates.goose'],cwd=ROOT).stdout.encode()
    env = os.environ.copy(); env['GOOSE_HOME'] = str(HERE/'goose-home')
    manifest = {'prepared_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'compiler':str(compiler),
                'compiler_sha256':digest(compiler),'compiler_version':cmd([compiler,'--version']).stdout,
                'gcc':cmd(['gcc','--version']).stdout,'flags':['--cc','gcc','-O2'],
                'platform':platform.platform(),'harness_path':'bench/updates.goose',
                'harness_sha256':hashlib.sha256(harness).hexdigest(),'cpu_affinity':settings.cpu,'snapshots':{},
                'host_controls':'no governor changes, no exclusive isolation, no dedicated warmup'}
    for label,ref in [('baseline',settings.before_ref),('candidate',settings.after_ref),('candidate-copy',settings.after_ref)]:
        snap=HERE/label; (snap/'bench').mkdir(parents=True,exist_ok=True)
        rev=cmd(['git','rev-parse','--verify',f'{ref}^{{commit}}'],cwd=ROOT).stdout.strip()
        for file in ['config.goose','toml.goose','vendor.goose','GOOSE_REVISION']:
            (snap/file).write_text(cmd(['git','show',f'{rev}:{file}'],cwd=ROOT).stdout)
        (snap/'bench/bench.goose').write_bytes(harness)
        if not manifest['compiler_version'].startswith('goose '+(snap/'GOOSE_REVISION').read_text().strip()[:7]+' '):
            raise SystemExit('compiler does not match snapshot GOOSE_REVISION')
        argv=['taskset','-c',str(settings.build_cpu),compiler,'build',snap/'bench/bench.goose','--cc','gcc','-O2','-o',snap/'benchmark']
        result=cmd(argv,env=env,cwd=ROOT); (snap/'build.txt').write_text(result.stdout+result.stderr)
        manifest['snapshots'][label]={'revision':rev,'build_argv':[str(a) for a in argv],
            'source_sha256':{file:digest(snap/file) for file in ['config.goose','toml.goose','vendor.goose','bench/bench.goose']},
            'binary_sha256':digest(snap/'benchmark')}
    for name in ['scalar-updates-paired','scalar-updates-repeat','scalar-core-paired','scalar-core-repeat']:
        path=ROOT/f'bench/results/{name}.json'; data=json.loads(path.read_text())
        manifest.setdefault('prior_records',{})[name]={'sha256':digest(path),'recorded_utc':data['recorded_utc'],
            'harness_sha256':data['harness_sha256'],'iterations_per_batch':data['iterations_per_batch'],'pairs':data['pairs']}
    dump(HERE/'manifest.json',manifest)
    print(json.dumps(portable(manifest),indent=2))
def parse_counters(stderr):
    raw=[dict(zip(('sample','bytes','calls','cycles','instructions','enabled_ns','running_ns'),map(int,match)))
         for match in re.findall(r'FC sample=(\d+) bytes=(\d+) calls=(\d+) cycles=(\d+) instructions=(\d+) enabled=(\d+) running=(\d+)',stderr)]
    if len(raw)!=42 or [row['sample'] for row in raw]!=list(range(42)):
        raise ValueError('invalid counter sample sequence')
    if any(row['cycles']<=0 or row['instructions']<=0 for row in raw):
        raise ValueError('missing PMU counter values')
    if any(row['enabled_ns']<=0 or row['enabled_ns']!=row['running_ns'] for row in raw):
        raise ValueError('PMU coverage is incomplete; no scaling is applied')
    return raw

def verify_artifacts(snapshots, instrumented):
    manifest_path=HERE/('instrumentation-manifest.json' if instrumented else 'manifest.json')
    manifest=json.loads(manifest_path.read_text())
    for label in set(snapshots):
        snapshot=manifest['snapshots'][label]
        for name, expected in snapshot['source_sha256'].items():
            path=HERE/label/name
            if not path.is_file() or digest(path)!=expected:
                raise ValueError(f'snapshot hash mismatch: {label}/{name}')
        binary=HERE/label/('instrumented' if instrumented else 'benchmark')
        expected=(manifest['instrumentation']['snapshots'][label] if instrumented else snapshot)['binary_sha256']
        if not binary.is_file() or digest(binary)!=expected:
            raise ValueError(f'binary hash mismatch: {label}')
    return digest(manifest_path)

def series(args):
    mappings={'same-binary':('candidate','candidate'),'same-source':('candidate','candidate-copy'),
              'ab':('baseline','candidate'),'ba-labels':('candidate','baseline')}
    left,right=mappings[args.control]
    manifest_hash=verify_artifacts((left,right),args.instrumented)
    records=[]; start=time.time()
    for pair in range(args.pairs):
        order=['left','right'] if pair%2==0 else ['right','left']
        if args.reverse: order.reverse()
        for label in order:
            if verify_artifacts((left,right),args.instrumented)!=manifest_hash:
                raise ValueError('manifest changed during measurement')
            snap={'left':left,'right':right}[label]
            argv=['taskset','-c',str(settings.cpu)]
            if args.perf:
                argv+=['perf','stat','-x',';','-e','cpu_atom/cycles/u,cpu_atom/instructions/u,task-clock,context-switches,cpu-migrations,page-faults','--']
            argv += [str(HERE/snap/('instrumented' if args.instrumented else 'benchmark')),str(args.count)]
            begin=time.time(); result=cmd(argv,cwd=ROOT)
            fixtures=measure.parse_fixtures(result.stdout,measure.UPDATE_FIXTURE_NAMES)
            record={'pair':pair,'label':label,'snapshot':snap,'start_unix':begin,'elapsed_s':time.time()-begin,
                    'argv':argv,'fixtures':fixtures,'stdout':result.stdout,'perf_stderr':result.stderr}
            if args.instrumented:
                raw=parse_counters(result.stderr)
                for index,name in enumerate(measure.UPDATE_FIXTURE_NAMES):
                    fixtures[name]['counter_samples']=raw[index*7:(index+1)*7]
            records.append(record)
            print(json.dumps({'pair':pair,'label':label,'snapshot':snap,'elapsed_s':record['elapsed_s'],
                'fallback_median_ns':{k:v['median_ns'] for k,v in fixtures.items() if k in FALLBACK}}),flush=True)
    checks=records[0]['fixtures']
    assert all(all(r['fixtures'][k]['checksum']==v['checksum'] for k,v in checks.items()) for r in records)
    summary={}
    for name in FALLBACK:
        left_m=[r['fixtures'][name]['median_ns'] for r in records if r['label']=='left']
        right_m=[r['fixtures'][name]['median_ns'] for r in records if r['label']=='right']
        ratios=[]
        for pair in range(args.pairs):
            a={r['label']:r['fixtures'][name]['median_ns'] for r in records if r['pair']==pair}
            ratios.append(a['right']/a['left'])
        summary[name]={'left_ns':statistics.median(left_m),'right_ns':statistics.median(right_m),
            'right_left_ratio':statistics.median(right_m)/statistics.median(left_m),
            'paired_ratios':ratios,'paired_median_ratio':statistics.median(ratios)}
    output={'control':args.control,'mapping':{'left':left,'right':right},'reverse_initial_order':args.reverse,
            'count':args.count,'batches':7,'pairs':args.pairs,'start_unix':start,'elapsed_s':time.time()-start,
            'instrumented':args.instrumented,
            'manifest_sha256':manifest_hash,
            'records':records,'summary':summary}
    if verify_artifacts((left,right),args.instrumented)!=manifest_hash:
        raise ValueError('manifest changed during measurement')
    dump(HERE/args.output,output); print(json.dumps(summary,indent=2))
    # An operational alert, not a statistical conclusion: A/B fallback >5% is red.
    if args.control in ('ab','ba-labels'):
        normalized=[v['right_left_ratio'] if args.control=='ab' else 1/v['right_left_ratio'] for v in summary.values()]
        print('RED: fallback slowdown above 5%' if any(r>1.05 for r in normalized) else 'GREEN: no fallback slowdown above 5%')
        return 1 if any(r>1.05 for r in normalized) else 0
    return 0
if __name__=='__main__':
    p=argparse.ArgumentParser(parents=[location]); p.add_argument('--prepare',action='store_true')
    p.add_argument('--control',choices=['same-binary','same-source','ab','ba-labels'])
    p.add_argument('--count',type=int,default=50); p.add_argument('--pairs',type=int,default=12)
    p.add_argument('--reverse',action='store_true'); p.add_argument('--perf',action='store_true')
    p.add_argument('--instrumented',action='store_true')
    p.add_argument('--output',default='record.json'); args=p.parse_args()
    if not 1 <= args.count <= 100000 or not 1 <= args.pairs <= 20:
        p.error('count must be 1..100000 and pairs 1..20')
    if settings.cpu not in os.sched_getaffinity(0) or settings.build_cpu not in os.sched_getaffinity(0):
        p.error('CPU is outside this process affinity')
    if not args.prepare and args.control is None:
        p.error('--control is required unless preparing')
    lock=HERE/'.active.lock'
    try:
        descriptor=os.open(lock,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    except FileExistsError:
        p.error('workdir is active or has a stale lock; use a distinct workdir')
    os.write(descriptor,str(os.getpid()).encode());os.close(descriptor)
    atexit.register(lambda: lock.unlink(missing_ok=True))
    try:
        if args.prepare: prepare()
        else: raise SystemExit(series(args))
    except Exception as error:
        print(f'record rejected: {error}',file=__import__('sys').stderr)
        raise SystemExit(2)
