#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build two exact revisions with one harness and run alternating paired samples.

All snapshots and executables are ignored local benchmark artifacts. This script
never modifies a Git checkout or weakens validation in the measured library.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True, timeout=120, **kwargs).stdout


def parse_fixtures(output):
    """Reject corrupt timing records before computing or publishing statistics."""
    pattern = re.compile(r"^(.+) samples_ns=(\[.*\]) checksum=(-?\d+)$")
    fixtures = {}
    for line in output.splitlines():
        match = pattern.fullmatch(line)
        if not match:
            continue
        name = match[1]
        if name in fixtures:
            raise ValueError(f"duplicate benchmark fixture: {name}")
        samples = json.loads(match[2])
        if type(samples) is not list or len(samples) != 7:
            raise ValueError(f"expected seven timing samples: {name}")
        for value in samples:
            if type(value) not in (int, float):
                raise ValueError(f"timing must be a number, excluding booleans: {name}")
            try:
                valid = math.isfinite(value) and value >= 0
            except OverflowError:
                valid = False
            if not valid:
                raise ValueError(f"timing must be finite and nonnegative: {name}")
        fixtures[name] = {"samples_ns": samples, "median_ns": statistics.median(samples),
                          "checksum": int(match[3])}
    if len(fixtures) != 16:
        raise ValueError(f"expected 16 benchmark fixtures, got {len(fixtures)}")
    return fixtures


def write_record(path, result):
    """Publish one complete strict-JSON record without truncating an old result."""
    path = Path(path)
    payload = json.dumps(result, indent=2, allow_nan=False) + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".measurement-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(payload)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--goose", type=Path, required=True)
    parser.add_argument("--before-ref", required=True)
    parser.add_argument("--after-ref", default="HEAD")
    parser.add_argument("--iterations", type=int, default=1000)
    parser.add_argument("--pairs", type=int, default=4)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 100000 or not 1 <= args.pairs <= 20:
        parser.error("iterations must be 1..100000 and pairs 1..20")
    if args.cpu is not None and args.cpu not in os.sched_getaffinity(0):
        parser.error("requested CPU is outside this process's affinity")
    compiler = str(args.goose.resolve())
    compiler_version = run([compiler, "--version"]).strip()
    harness = (ROOT / "bench/bench.goose").read_bytes()
    directory = ROOT / ".build/paired"
    directory.mkdir(parents=True, exist_ok=True)
    # Every invocation owns its sources and binaries until all samples finish.
    # Sharing only the parent directory permits concurrent runs without mixing
    # historical revisions or retaining stale source files.
    with tempfile.TemporaryDirectory(prefix="run-", dir=directory) as workspace:
        directory = Path(workspace)
        revisions = {}
        binaries = {}
        pins = {}
        for label, ref in (("before", args.before_ref), ("after", args.after_ref)):
            revision = run(["git", "rev-parse", "--verify", f"{ref}^{{commit}}"], cwd=ROOT).strip()
            revisions[label] = revision
            snapshot = directory / label
            snapshot.mkdir(exist_ok=True)
            for name in ("config.goose", "toml.goose", "vendor.goose"):
                (snapshot / name).write_text(run(["git", "show", f"{revision}:{name}"], cwd=ROOT))
            pins[label] = run(["git", "show", f"{revision}:GOOSE_REVISION"], cwd=ROOT).strip()
            (snapshot / "bench").mkdir(exist_ok=True)
            source = snapshot / "bench/bench.goose"
            source.write_bytes(harness)
            binary = snapshot / "benchmark"
            run([compiler, "build", str(source), "--cc", "gcc", "-O2", "-o", str(binary)], cwd=ROOT)
            binaries[label] = str(binary)
        if pins["before"] != pins["after"]:
            parser.error("paired revisions use different compiler pins")
        if not compiler_version.startswith(f"goose {pins['after'][:7]} "):
            parser.error("the provided compiler does not match the pinned source revision")
        measurements = []
        for pair in range(args.pairs):
            order = ("before", "after") if pair % 2 == 0 else ("after", "before")
            for label in order:
                command = [binaries[label], str(args.iterations)]
                if args.cpu is not None:
                    command = ["taskset", "-c", str(args.cpu), *command]
                output = run(command, cwd=ROOT)
                try:
                    fixtures = parse_fixtures(output)
                except ValueError as error:
                    raise SystemExit(f"invalid benchmark output ({label}, pair {pair + 1}): {error}") from error
                measurements.append({"pair": pair, "revision": label, "fixtures": fixtures})
                print(f"Measured pair {pair + 1}/{args.pairs}: {label}", flush=True)
        # Identical checksums guard behavior across both revisions and every pair.
        first = measurements[0]["fixtures"]
        for measurement in measurements:
            actual = measurement["fixtures"]
            if set(actual) != set(first) or any(actual[key]["checksum"] != first[key]["checksum"] for key in first):
                raise SystemExit("fixture names or checksums differ between paired runs")
        cpu_name = "unknown"
        if Path("/proc/cpuinfo").exists():
            for line in Path("/proc/cpuinfo").read_text().splitlines():
                if line.startswith("model name"):
                    cpu_name = line.split(":", 1)[1].strip()
                    break
        result = {"recorded_utc": datetime.now(timezone.utc).isoformat(), "revisions": revisions,
                  "compiler_revision": pins["after"], "compiler_version": compiler_version, "gcc": run(["gcc", "--version"]).splitlines()[0],
                  "platform": platform.platform(), "cpu": cpu_name, "cpu_affinity": args.cpu,
                  "flags": "gcc -O2; -lm -pthread -ldl", "iterations_per_batch": args.iterations,
                  "batches": 7, "pairs": args.pairs, "harness_sha256": hashlib.sha256(harness).hexdigest(),
                  "frequency_governor": "uncontrolled", "warmup": "fixture setup only",
                  "measurements": measurements}
        write_record(args.output, result)
        print(f"Saved {len(measurements)} runs, 16 fixtures each, to {args.output}")


if __name__ == "__main__":
    main()
