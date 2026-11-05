#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Checked duration workloads against pinned Viper/Koanf public getter paths."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import tempfile

from measure import ROOT, parse_fixtures, write_record

FIXTURES = ('duration-get', 'duration-override', 'duration-json', 'duration-toml')
MODULES = ('config.goose', 'toml.goose', 'vendor.goose', 'json_layer.goose', 'bindings.goose', 'reload.goose')
RUNTIME_ENV = {'GOMAXPROCS': '1', 'GOGC': '100', 'GOMEMLIMIT': 'off', 'GODEBUG': ''}

def run(command, measured=False, **kwargs):
    process = subprocess.run(list(map(str, command)), check=True, capture_output=True,
                          text=True, timeout=300, **kwargs)
    if measured and process.stderr:
        raise ValueError(f'measured process emitted stderr: {process.stderr}')
    return process.stdout

def sha(data): return hashlib.sha256(data).hexdigest()

def parse_durations(output, count):
    if len(output.splitlines()) != len(FIXTURES): raise ValueError('expected exactly four duration fixtures')
    fixtures = parse_fixtures(output, FIXTURES)
    for name, row in fixtures.items():
        expected = 7 * (((count+1)//2)*250000000+(count//2)*1500000000)
        if row['checksum'] != expected: raise ValueError(f'incorrect duration checksum: {name}')
    return fixtures

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--goose', type=Path, required=True)
    p.add_argument('--revision', default='HEAD')
    p.add_argument('--iterations', type=int, default=10000)
    p.add_argument('--rounds', type=int, default=9)
    p.add_argument('--seed', type=int, default=606)
    p.add_argument('--cpu', type=int, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--disassembly-output', type=Path, help='retain native assembly from the exact measured Goose binary')
    a = p.parse_args()
    if not 1 <= a.iterations <= 100000 or not 1 <= a.rounds <= 12: p.error('iterations1..100000; rounds1..12')
    if a.cpu not in os.sched_getaffinity(0): p.error('CPU outside affinity')
    os.sched_setaffinity(0, {a.cpu})
    revision = run(['git', 'rev-parse', '--verify', '--end-of-options', f'{a.revision}^{{commit}}'], cwd=ROOT).strip()
    compiler = a.goose.resolve(strict=True)
    pin = run(['git', 'show', f'{revision}:GOOSE_REVISION'], cwd=ROOT).strip()
    version = run([compiler, '--version']).strip()
    if not version.startswith(f'goose {pin[:7]} '): p.error('compiler does not match source pin')
    gcc = Path(shutil.which('gcc')).resolve(strict=True)
    toolchain_root = compiler.parent.parent
    stdlib_paths = sorted((toolchain_root/'stdlib').rglob('*.goose'))
    if not stdlib_paths: p.error('adjacent pinned stdlib missing')
    toolchain_paths = stdlib_paths + sorted((toolchain_root/'src/runtime').glob('*.h'))
    if (toolchain_root/'src/runtime_inline.h').is_file(): toolchain_paths.append(toolchain_root/'src/runtime_inline.h')
    toolchain_hashes = {str(path.relative_to(compiler.parent.parent)): sha(path.read_bytes()) for path in toolchain_paths}
    if not toolchain_hashes: p.error('adjacent pinned stdlib missing')
    gcc_hash = sha(gcc.read_bytes())
    parent = ROOT/'.build/duration-comparison'; parent.mkdir(exist_ok=True, parents=True)
    hashes = {'bench/compare_durations.py': sha(Path(__file__).read_bytes()), 'bench/measure.py': sha((ROOT/'bench/measure.py').read_bytes())}
    with tempfile.TemporaryDirectory(prefix='run-', dir=parent) as tmp:
        work = Path(tmp); source = work/'source'; (source/'bench').mkdir(parents=True)
        for name in MODULES:
            data = subprocess.check_output(['git', 'show', f'{revision}:{name}'], cwd=ROOT, timeout=30)
            (source/name).write_bytes(data); hashes[name] = sha(data)
        harness = (ROOT/'bench/durations.goose').read_bytes(); (source/'bench/durations.goose').write_bytes(harness); hashes['bench/durations.goose'] = sha(harness)
        adapters = work/'adapters'; adapters.mkdir()
        for name in ('go.mod', 'go.sum', 'main.go'):
            data = (ROOT/'bench/competitors'/name).read_bytes(); (adapters/name).write_bytes(data); hashes['bench/competitors/'+name] = sha(data)
        goose = work/'goose-benchmark'; competitor = work/'competitors'
        env = {key: os.environ[key] for key in ('PATH', 'HOME') if key in os.environ}
        env.update(LANG='C', TZ='UTC', GOOSE_HOME=str(work/'goose-home'), GOOSE_PROGRESS='plain')
        run([compiler, 'build', source/'bench/durations.goose', '--cc', 'gcc', '-O2', '-o', goose], cwd=ROOT, env=env)
        run(['go', 'build', '-mod=readonly', '-trimpath', '-buildvcs=false', '-o', competitor, '.'], cwd=adapters, env=dict(os.environ, GOWORK='off', GOFLAGS=''))
        metadata = json.loads(run([competitor, 'metadata'], env=RUNTIME_ENV))
        assembly_hash = None
        if a.disassembly_output is not None:
            assembly = run(['objdump', '-d', goose])
            a.disassembly_output.parent.mkdir(parents=True, exist_ok=True)
            a.disassembly_output.write_text(assembly)
            assembly_hash = sha(assembly.encode())
        binary_hashes = {'compiler': sha(compiler.read_bytes()), 'goose_benchmark': sha(goose.read_bytes()), 'competitors': sha(competitor.read_bytes())}
        labels = ('goose-config', 'viper', 'koanf'); runs = []; rng = random.Random(a.seed)
        for count in (1, 2, 3):
            for label in labels:
                command = [goose, str(count)] if label == 'goose-config' else [competitor, label, str(count), 'durations']
                parse_durations(run(command, cwd=ROOT, env=RUNTIME_ENV, measured=True), count)
        started = datetime.now(timezone.utc).isoformat()
        for round_id in range(a.rounds):
            order = list(labels); rng.shuffle(order)
            for label in order:
                command = [goose, str(a.iterations)] if label == 'goose-config' else [competitor, label, str(a.iterations), 'durations']
                output = run(command, cwd=ROOT, env=RUNTIME_ENV, measured=True)
                fixtures = parse_durations(output, a.iterations)
                runs.append({'round': round_id, 'library': label, 'raw_stdout': output, 'fixtures': fixtures})
                print(f'round {round_id+1}/{a.rounds}: {label}', flush=True)
        if toolchain_hashes != {str(path.relative_to(compiler.parent.parent)): sha(path.read_bytes()) for path in toolchain_paths} or gcc_hash != sha(gcc.read_bytes()): raise ValueError('toolchain identity changed')
        if binary_hashes != {'compiler': sha(compiler.read_bytes()), 'goose_benchmark': sha(goose.read_bytes()), 'competitors': sha(competitor.read_bytes())}: raise ValueError('measured binary identity changed')
        summary = {label: {key: statistics.median(r['fixtures'][key]['median_ns'] for r in runs if r['library']==label) for key in FIXTURES} for label in labels}
        cpu = next((line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')), 'unknown')
        result = {
            'native_disassembly_sha256': assembly_hash,
            'utc_start': started,
            'recorded_utc': datetime.now(timezone.utc).isoformat(),
            'revision': revision,
            'goose_revision': pin,
            'goose_version': version,
            'gcc': run(['gcc','--version']).splitlines()[0],
            'platform': platform.platform(),
            'cpu': cpu,
            'actual_affinity': sorted(os.sched_getaffinity(0)),
            'source_sha256': hashes,
            'toolchain_source_sha256': toolchain_hashes,
            'gcc_sha256': gcc_hash,
            'binary_sha256': binary_hashes,
            'competitor_metadata': metadata,
            'iterations': a.iterations,
            'rounds': a.rounds,
            'seed': a.seed,
            'samples_per_run': 7,
            'runtime_environment': RUNTIME_ENV,
            'flags': {'goose': 'GCC -O2', 'go': 'go build -mod=readonly -trimpath -buildvcs=false'},
            'smoke_only': a.iterations<=2,
            'limitations': ['Shared host, no exclusive isolation or causal speed claim.', 'Successful one-field writes and two-key mixed getter; full feature/error semantics are not equivalent.', 'Goose validates and parses at write time and retains nanoseconds/provenance; dynamic competitors parse through their duration getters.', 'Getter alternates two keys with distinct values; it excludes initial write/parse; override and JSON/TOML cases include write plus getter.', 'Schema/setup/fixtures are outside timers; no file IO, reload triggers, failures, list durations or memory are timed.', 'Positive250ms/1.5s tokens are exactly represented by all three parsers; precision/overflow behavior is checked separately by CONFIG model tests.'],
            'runs': runs,
            'median_of_run_medians_ns': summary,
        }
        write_record(a.output, result); print(json.dumps(summary, indent=2))

if __name__ == '__main__': main()
