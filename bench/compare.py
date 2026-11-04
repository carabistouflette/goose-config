#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Measure the shared Goose/Viper/Koanf workload subset; never claim full parity."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

from measure import ROOT, parse_fixtures, write_record

SHARED = ("lookup-small", "lookup-mixed-wide", "lookup-last-wide", "toml-small")


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True,
                          timeout=300, **kwargs).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--goose", type=Path, required=True)
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--iterations", type=int, default=10000)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 100000 or not 1 <= args.rounds <= 12:
        parser.error("iterations must be 1..100000 and rounds 1..12")
    if args.cpu not in os.sched_getaffinity(0):
        parser.error("CPU is outside this process's affinity")
    revision = run(["git", "rev-parse", "--verify", f"{args.revision}^{{commit}}"], cwd=ROOT).strip()
    pin = run(["git", "show", f"{revision}:GOOSE_REVISION"], cwd=ROOT).strip()
    compiler = str(args.goose.resolve(strict=True))
    version = run([compiler, "--version"]).strip()
    if not version.startswith(f"goose {pin[:7]} "):
        parser.error("Goose compiler does not match the source pin")
    parent = ROOT / ".build/comparison"
    parent.mkdir(parents=True, exist_ok=True)
    go_env = dict(os.environ, GOWORK="off", GOFLAGS="")
    hashes = {}
    with tempfile.TemporaryDirectory(prefix="run-", dir=parent) as temporary:
        workspace = Path(temporary)
        adapter_source = workspace / "adapters"
        adapter_source.mkdir()
        for name in ("go.mod", "go.sum", "main.go"):
            data = (ROOT / "bench/competitors" / name).read_bytes()
            (adapter_source / name).write_bytes(data)
            hashes[f"competitors/{name}"] = hashlib.sha256(data).hexdigest()
        source = workspace / "source"
        (source / "bench").mkdir(parents=True)
        for name in ("config.goose", "toml.goose", "vendor.goose", "bench/bench.goose"):
            data = subprocess.run(["git", "show", f"{revision}:{name}"], cwd=ROOT,
                                  check=True, capture_output=True, timeout=30).stdout
            (source / name).write_bytes(data)
            hashes[name] = hashlib.sha256(data).hexdigest()
        goose_binary = workspace / "goose-bench"
        run([compiler, "build", str(source / "bench/bench.goose"), "--cc", "gcc",
             "-O2", "-o", str(goose_binary)], cwd=ROOT)
        competitor = workspace / "competitors"
        run(["go", "build", "-mod=readonly", "-trimpath", "-buildvcs=false", "-o", str(competitor), "."],
            cwd=adapter_source, env=go_env)
        metadata = json.loads(run(["taskset", "-c", str(args.cpu), str(competitor), "metadata"], env=go_env))
        runs = []
        labels = ("goose-config", "viper", "koanf")
        for round_id in range(args.rounds):
            order = labels[round_id % 3:] + labels[:round_id % 3]
            for label in order:
                command = ([str(goose_binary), str(args.iterations), "shared"] if label == "goose-config"
                           else [str(competitor), label, str(args.iterations)])
                output = run(["taskset", "-c", str(args.cpu), *command], cwd=ROOT, env=go_env)
                fixtures = parse_fixtures(output, SHARED)
                runs.append({"round": round_id, "library": label,
                             "fixtures": {key: fixtures[key] for key in SHARED}})
                print(f"round {round_id + 1}/{args.rounds}: {label}", flush=True)
        baseline = runs[0]["fixtures"]
        for row in runs:
            if any(row["fixtures"][key]["checksum"] != baseline[key]["checksum"] for key in SHARED):
                raise SystemExit("cross-library checksum mismatch; no result published")
        summary = {label: {key: statistics.median(row["fixtures"][key]["median_ns"]
                   for row in runs if row["library"] == label) for key in SHARED} for label in labels}
        cpu_info = Path("/proc/cpuinfo").read_text()
        cpu_name = next((line.split(":", 1)[1].strip() for line in cpu_info.splitlines()
                         if line.startswith("model name")), "unknown")
        result = {"recorded_utc": datetime.now(timezone.utc).isoformat(), "revision": revision,
                  "goose_revision": pin, "goose_version": version, "competitor_metadata": metadata,
                  "gcc": run(["gcc", "--version"]).splitlines()[0], "platform": platform.platform(),
                  "cpu": cpu_name, "cpu_affinity": args.cpu, "iterations": args.iterations,
                  "rounds": args.rounds, "samples_per_run": 7, "source_sha256": hashes,
                  "flags": {"goose": "gcc -O2", "go": "go build -mod=readonly -trimpath -buildvcs=false"},
                  "runtime_environment": {key: go_env.get(key) for key in
                                          ("GOGC", "GOMEMLIMIT", "GODEBUG", "GOEXPERIMENT")},
                  "limitations": ["Cross-language/runtime measurements; scalar shared subset only.",
                                  "Goose additionally validates schema and types and commits atomically.",
                                  "Goose returns source metadata; competitors do not match this contract.",
                                  "TOML fixture includes merging and an integer getter; no I/O.",
                                  "Frequency, thermals and other system load uncontrolled.",
                                  "No dedicated warmup; setup occurs before timing."],
                  "runs": runs, "median_of_run_medians_ns": summary}
        write_record(args.output, result)
        print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
