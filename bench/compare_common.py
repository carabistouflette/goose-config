#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Measure shared JSON/TOML list replacement and current-source reload workloads."""
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

COMMON = ("json-lists", "toml-lists", "reload-removal")
MODULES = ("config.goose", "toml.goose", "vendor.goose", "json_layer.goose",
           "bindings.goose", "reload.goose")


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True,
                          timeout=300, **kwargs).stdout


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--goose", type=Path, required=True)
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--iterations", type=int, default=1000)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 100000 or not 1 <= args.rounds <= 12:
        parser.error("iterations must be 1..100000 and rounds 1..12")
    if args.cpu not in os.sched_getaffinity(0):
        parser.error("CPU is outside this process's affinity")
    revision = run(["git", "rev-parse", "--verify", f"{args.revision}^{{commit}}"], cwd=ROOT).strip()
    pin_data = subprocess.run(["git", "show", f"{revision}:GOOSE_REVISION"], cwd=ROOT,
                              check=True, capture_output=True, timeout=30).stdout
    pin = pin_data.decode().strip()
    compiler = str(args.goose.resolve(strict=True))
    version = run([compiler, "--version"]).strip()
    if not version.startswith(f"goose {pin[:7]} "):
        parser.error("Goose compiler does not match the source pin")
    parent = ROOT / ".build/common-bench"
    parent.mkdir(parents=True, exist_ok=True)
    go_env = dict(os.environ, GOWORK="off", GOFLAGS="")
    hashes = {"GOOSE_REVISION": sha256(pin_data),
              "bench/compare_common.py": sha256(Path(__file__).read_bytes()),
              "bench/measure.py": sha256((ROOT / "bench/measure.py").read_bytes())}
    with tempfile.TemporaryDirectory(prefix="run-", dir=parent) as temporary:
        workspace = Path(temporary)
        goose_env = dict(os.environ, GOOSE_HOME=str(workspace / "goose-home"))
        adapter_source = workspace / "adapters"
        adapter_source.mkdir()
        for name in ("go.mod", "go.sum", "main.go"):
            data = (ROOT / "bench/competitors" / name).read_bytes()
            (adapter_source / name).write_bytes(data)
            hashes[f"bench/competitors/{name}"] = sha256(data)
        source = workspace / "source"
        (source / "bench").mkdir(parents=True)
        # Every runtime module comes from the same immutable commit, even when
        # unrelated files in the working checkout are being edited concurrently.
        for name in MODULES:
            data = subprocess.run(["git", "show", f"{revision}:{name}"], cwd=ROOT,
                                  check=True, capture_output=True, timeout=30).stdout
            (source / name).write_bytes(data)
            hashes[name] = sha256(data)
        harness = (ROOT / "bench/common.goose").read_bytes()
        (source / "bench/common.goose").write_bytes(harness)
        hashes["bench/common.goose"] = sha256(harness)
        goose_binary = workspace / "goose-bench"
        run([compiler, "build", str(source / "bench/common.goose"), "--cc", "gcc",
             "-O2", "-o", str(goose_binary)], cwd=ROOT, env=goose_env)
        competitor = workspace / "competitors"
        run(["go", "build", "-mod=readonly", "-trimpath", "-buildvcs=false", "-o", str(competitor), "."],
            cwd=adapter_source, env=go_env)
        metadata = json.loads(run(["taskset", "-c", str(args.cpu), str(competitor), "metadata"], env=go_env))
        runs = []
        labels = ("goose-config", "viper", "koanf")
        for round_id in range(args.rounds):
            order = labels[round_id % 3:] + labels[:round_id % 3]
            for label in order:
                command = ([str(goose_binary), str(args.iterations)] if label == "goose-config"
                           else [str(competitor), label, str(args.iterations), "common"])
                output = run(["taskset", "-c", str(args.cpu), *command], cwd=ROOT,
                             env=goose_env if label == "goose-config" else go_env)
                fixtures = parse_fixtures(output, COMMON)
                runs.append({"round": round_id, "library": label, "raw_stdout": output,
                             "fixtures": {key: fixtures[key] for key in COMMON}})
                print(f"round {round_id + 1}/{args.rounds}: {label}", flush=True)
        baseline = runs[0]["fixtures"]
        for row in runs:
            if any(row["fixtures"][key]["checksum"] != baseline[key]["checksum"] for key in COMMON):
                raise SystemExit("cross-library checksum mismatch; no result published")
        summary = {label: {key: statistics.median(row["fixtures"][key]["median_ns"]
                   for row in runs if row["library"] == label) for key in COMMON} for label in labels}
        cpu_info = Path("/proc/cpuinfo").read_text()
        cpu_name = next((line.split(":", 1)[1].strip() for line in cpu_info.splitlines()
                         if line.startswith("model name")), "unknown")
        result = {"recorded_utc": datetime.now(timezone.utc).isoformat(), "revision": revision,
                  "goose_revision": pin, "goose_version": version, "competitor_metadata": metadata,
                  "gcc": run(["gcc", "--version"]).splitlines()[0], "platform": platform.platform(),
                  "cpu": cpu_name, "cpu_affinity": args.cpu, "iterations": args.iterations,
                  "rounds": args.rounds, "samples_per_run": 7, "source_sha256": hashes,
                  "binary_sha256": {"compiler": sha256(Path(compiler).read_bytes()),
                                    "goose_benchmark": sha256(goose_binary.read_bytes()),
                                    "competitors": sha256(competitor.read_bytes())},
                  "flags": {"goose": "gcc -O2", "go": "go build -mod=readonly -trimpath -buildvcs=false"},
                  "runtime_environment": {key: go_env.get(key) for key in
                                          ("GOMAXPROCS", "GOGC", "GOMEMLIMIT", "GODEBUG", "GOEXPERIMENT")},
                  "limitations": ["Cross-language/runtime measurements; successful shared feature workloads only.",
                                  "Goose validates declared schema, integer range 1..65535 and strict types; adapters do not.",
                                  "Goose returns independently owned i64 lists; Go public list getters have different conversion and ownership contracts.",
                                  "JSON/list fixtures use small exact integers; they do not compare large-integer precision or malformed input handling.",
                                  "Goose tracks per-setting sources and publishes reload atomically; adapter paths do not supply these contracts.",
                                  "Reload times fresh current-source replay: defaults plus current JSON; Viper/Koanf create new instances each operation.",
                                  "List fixtures parse/merge existing instances and read first integer plus list length; no file I/O.",
                                  "Documents and schemas are prepared before timing; reload source assembly/default registration is timed.",
                                  "Final complete list/name/port checks occur outside timing; every checksum must match before publication.",
                                  "Frequency, thermals and other system load uncontrolled; setup only, no dedicated warmup."],
                  "runs": runs, "median_of_run_medians_ns": summary}
        write_record(args.output, result)
        print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
