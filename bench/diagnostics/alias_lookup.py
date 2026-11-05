#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Manual cached lookup regression probe; not an elapsed-time CI gate.

Build both immutable revisions at one source path. Reuse the same before binary
for A/B controls. Exit1 means the selected ratio budget was exceeded; exit2
means the identical-binary control is outside its tolerance. Retain every run.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import statistics
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from measure import ROOT, parse_fixtures, write_record

HARNESS_REF = '498124392f224b31f2ea2fa8489ee28f80b9f288'
MODULES = ('config.goose', 'toml.goose', 'vendor.goose', 'json_layer.goose', 'bindings.goose', 'reload.goose')

def run(command, **kwargs):
    return subprocess.run(list(map(str, command)), capture_output=True, text=True,
                          check=True, timeout=180, **kwargs).stdout

def sha(data):
    return hashlib.sha256(data).hexdigest()

def verify_binaries(workspace, hashes):
    if not isinstance(hashes, dict) or set(hashes) != {'before', 'after'}:
        raise ValueError('cached binary inventory must contain before and after')
    for label, digest in hashes.items():
        if sha((workspace/label).read_bytes()) != digest:
            raise ValueError('cached binary changed')

def classify(medians, max_ratio, tolerance):
    if medians['before-A'] <= 0:
        return None, None, 'inconclusive'
    ratio = medians['after']/medians['before-A']
    control = medians['before-B']/medians['before-A']
    verdict = 'inconclusive' if abs(control-1) > tolerance else 'regression' if ratio > max_ratio else 'within-budget'
    return ratio, control, verdict

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--goose', type=Path, required=True)
    p.add_argument('--before-ref', required=True)
    p.add_argument('--after-ref', required=True)
    p.add_argument('--workspace', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--reuse', action='store_true')
    p.add_argument('--cpu', type=int, required=True)
    p.add_argument('--rounds', type=int, default=9)
    p.add_argument('--iterations', type=int, default=100000)
    p.add_argument('--fields', type=int, default=1)
    p.add_argument('--width', type=int, default=1)
    p.add_argument('--case', choices=('lookup', 'integer-update'), default='lookup')
    p.add_argument('--seed', type=int, default=606)
    p.add_argument('--max-ratio', type=float, default=1.15)
    p.add_argument('--control-tolerance', type=float, default=.10)
    a = p.parse_args()
    if not 1 <= a.rounds <= 30 or not 1 <= a.iterations <= 100000:
        p.error('rounds1..30; iterations1..100000')
    if not 1 <= a.fields <= 256 or not 1 <= a.width <= 4096:
        p.error('fields1..256; width1..4096')
    if not 1 <= a.max_ratio <= 10 or not 0 < a.control_tolerance <= .5:
        p.error('ratio1..10; tolerance>0..0.5')
    if a.cpu not in os.sched_getaffinity(0): p.error('CPU outside affinity')
    os.sched_setaffinity(0, {a.cpu})
    compiler = a.goose.resolve(strict=True)
    revisions = {label: run(['git', 'rev-parse', '--verify', '--end-of-options', f'{ref}^{{commit}}'], cwd=ROOT).strip()
                 for label, ref in [('before', a.before_ref), ('after', a.after_ref)]}
    pins = [run(['git', 'show', f'{ref}:GOOSE_REVISION'], cwd=ROOT).strip() for ref in revisions.values()]
    version = run([compiler, '--version']).strip()
    if pins[0] != pins[1] or not version.startswith(f'goose {pins[0][:7]} '): p.error('compiler pin mismatch')
    harness_path = 'bench/bench.goose' if a.case == 'lookup' else 'bench/updates.goose'
    harness = run(['git', 'show', f'{HARNESS_REF}:{harness_path}'], cwd=ROOT)
    marker = '    scenario("lookup-small"' if a.case == 'lookup' else '    scenario("update-text-boundary-large"'
    if harness.count(marker) != 1: raise ValueError('frozen harness marker changed')
    fixture = 'lookup-first-wide' if a.case == 'lookup' else 'update-integer-large'
    call = f'    scenario("{fixture}", count, {a.fields}, {a.width}, 0);\n}}\n' if a.case == 'lookup' else f'    scenario("{fixture}", count, 2);\n}}\n'
    harness = harness[:harness.index(marker)] + call
    source_hashes = {label: {name: sha(subprocess.check_output(['git','show',f'{ref}:{name}'], cwd=ROOT,timeout=30))
                             for name in MODULES} for label, ref in revisions.items()}
    gcc = Path(shutil.which('gcc')).resolve(strict=True)
    script_hash = sha(Path(__file__).read_bytes())
    inputs = [gcc, ROOT/'bench/measure.py', compiler.parent.parent/'src/runtime_inline.h', *sorted((compiler.parent.parent/'stdlib').rglob('*.goose')),
              *sorted((compiler.parent.parent/'src/runtime').glob('*.h'))]
    input_hashes = {str(path): sha(path.read_bytes()) for path in inputs}
    expected = {'revisions': revisions, 'source_sha256': source_hashes, 'compiler_sha256': sha(compiler.read_bytes()),
                'input_sha256': input_hashes, 'harness_sha256': sha(harness.encode()), 'recorder_sha256': script_hash, 'flags': 'GCC -O2'}
    workspace = a.workspace.resolve()
    manifest = workspace/'manifest.json'
    if a.reuse:
        cached = json.loads(manifest.read_text())
        if cached['inputs'] != expected: raise ValueError('cached inputs differ; use a new workspace')
    else:
        workspace.mkdir(parents=True, exist_ok=False)
        active = workspace/'active'; (active/'bench').mkdir(parents=True)
        env = {key: os.environ[key] for key in ('PATH','HOME') if key in os.environ}
        env.update(GOOSE_HOME=str(workspace/'goose-home'), LANG='C', TZ='UTC')
        for label, ref in revisions.items():
            for name in MODULES:
                (active/name).write_bytes(subprocess.check_output(['git','show',f'{ref}:{name}'],cwd=ROOT,timeout=30))
            (active/'bench/updates.goose').write_text(harness)
            run([compiler,'build',active/'bench/updates.goose','--cc','gcc','-O2','-o',workspace/label],env=env)
        cached = {'inputs': expected, 'binary_sha256': {label: sha((workspace/label).read_bytes()) for label in revisions}}
        manifest.write_text(json.dumps(cached,indent=2)+'\n')
    verify_binaries(workspace, cached['binary_sha256'])
    rng = random.Random(a.seed); rows = []; started = datetime.now(timezone.utc).isoformat()
    for round_id in range(a.rounds):
        order = ['before-A','before-B','after']; rng.shuffle(order)
        for label in order:
            binary = workspace/('after' if label == 'after' else 'before')
            result = subprocess.run([str(binary),str(a.iterations)],capture_output=True,text=True,check=True,timeout=120)
            if result.stderr: raise ValueError(result.stderr)
            row = parse_fixtures(result.stdout,(fixture,))[fixture]
            total = 7*a.iterations
            checksum = total*a.width if a.case == 'lookup' else 17*((total+1)//2)+29*(total//2)
            if row['checksum'] != checksum: raise ValueError('incorrect fixture checksum')
            rows.append({'round':round_id,'label':label,'raw_stdout':result.stdout,**row})
    medians = {label: statistics.median(r['median_ns'] for r in rows if r['label']==label)
               for label in ('before-A','before-B','after')}
    ratio, control, verdict = classify(medians, a.max_ratio, a.control_tolerance)
    if sha(compiler.read_bytes()) != expected['compiler_sha256'] or input_hashes != {str(path):sha(path.read_bytes()) for path in inputs}:
        raise ValueError('toolchain changed')
    verify_binaries(workspace, cached['binary_sha256'])
    if sha(Path(__file__).read_bytes()) != script_hash: raise ValueError('recorder changed')
    # The private cache manifest has exact local input paths. Public results use
    # only paths relative to the toolchain and generic GCC/helper labels.
    public_inputs = {str(path.relative_to(compiler.parent.parent)) if path.is_relative_to(compiler.parent.parent)
                     else ('gcc' if path==gcc else 'bench/measure.py'): input_hashes[str(path)] for path in inputs}
    record = {'utc_start': started,'recorded_utc':datetime.now(timezone.utc).isoformat(),
              'revisions':revisions,'source_sha256':source_hashes,'compiler_version':version,
              'compiler_sha256':expected['compiler_sha256'],'toolchain_input_sha256':public_inputs,
              'binary_sha256':cached['binary_sha256'],'harness_ref':HARNESS_REF,'harness_sha256':expected['harness_sha256'],
              'recorder_sha256':script_hash,'fixture':fixture,'harness_path':harness_path,
              'fields':a.fields if a.case == 'lookup' else 256,'value_bytes':a.width if a.case == 'lookup' else 4096,'iterations':a.iterations,'rounds':a.rounds,'seed':a.seed,
              'cpu_affinity':sorted(os.sched_getaffinity(0)),'flags':'GCC -O2','shared_host':True,
              'max_ratio':a.max_ratio,'control_tolerance':a.control_tolerance,'rows':rows,'medians_ns':medians,
              'after_before':ratio,'identical_binary_control':control,'verdict':verdict,
              'limitations':['Fixed frozen core harness; fixture label retained despite minimized dimensions.',
                             'Ratio budget is a diagnostic signal, not a causal percentage or CI performance guarantee.',
                             'Identical binary is reused only for before-A/B within this invocation.']}
    write_record(a.output,record)
    print(f'{verdict}: after/before={ratio}, identical-binary control={control}')
    return 2 if verdict=='inconclusive' else 1 if verdict=='regression' else 0
if __name__=='__main__':sys.exit(main())
