#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Measure fresh native env/CLI bindings and four-layer current-source replay."""
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

BINDINGS = ("env-bindings", "cli-lists", "reload-layers")
RUNTIME_ENV = {"GOOSE_BENCH_PORT": "9000", "GOOSE_BENCH_NAME": "worker",
               "GOOSE_BENCH_TAG": "a b c", "GOMAXPROCS": "1", "GOGC": "100",
               "GOMEMLIMIT": "off", "GODEBUG": ""}
MODULES = ("config.goose", "toml.goose", "vendor.goose", "json_layer.goose",
           "bindings.goose", "reload.goose")


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True,
                          timeout=300, **kwargs).stdout


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def parse_bindings(output, count):
    # Unlike the older lookup harness this protocol permits only fixture lines.
    if len(output.splitlines()) != len(BINDINGS):
        raise ValueError("expected exactly three fixture lines")
    fixtures = parse_fixtures(output, BINDINGS)
    expected = {"env-bindings": 7 * count * 9009, "cli-lists": 7 * count * 9008,
                "reload-layers": 7 * (((count + 1) // 2) * 9261 + (count // 2) * 8361)}
    for name, checksum in expected.items():
        if fixtures[name]["checksum"] != checksum:
            raise ValueError(f"unexpected checksum for {name}")
    return fixtures


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
    parent = ROOT / ".build/bindings-bench"
    parent.mkdir(parents=True, exist_ok=True)
    go_env = dict(os.environ, GOWORK="off", GOFLAGS="")
    hashes = {"GOOSE_REVISION": sha256(pin_data),
              "bench/compare_bindings.py": sha256(Path(__file__).read_bytes()),
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
        harness = (ROOT / "bench/bindings.goose").read_bytes()
        (source / "bench/bindings.goose").write_bytes(harness)
        hashes["bench/bindings.goose"] = sha256(harness)
        goose_binary = workspace / "goose-bench"
        run(["taskset", "-c", str(args.cpu), compiler, "build", str(source / "bench/bindings.goose"), "--cc", "gcc",
             "-O2", "-o", str(goose_binary)], cwd=ROOT, env=goose_env)
        competitor = workspace / "competitors"
        run(["taskset", "-c", str(args.cpu), "go", "build", "-mod=readonly", "-trimpath", "-buildvcs=false", "-o", str(competitor), "."],
            cwd=adapter_source, env=go_env)
        metadata = json.loads(run(["taskset", "-c", str(args.cpu), str(competitor), "metadata"], env=RUNTIME_ENV))
        runs = []
        labels = ("goose-config", "viper", "koanf")
        for round_id in range(args.rounds):
            order = labels[round_id % 3:] + labels[:round_id % 3]
            for label in order:
                command = ([str(goose_binary), str(args.iterations)] if label == "goose-config"
                           else [str(competitor), label, str(args.iterations), "bindings"])
                output = run(["taskset", "-c", str(args.cpu), *command], cwd=ROOT,
                             env=RUNTIME_ENV)
                fixtures = parse_bindings(output, args.iterations)
                runs.append({"round": round_id, "library": label, "raw_stdout": output,
                             "fixtures": {key: fixtures[key] for key in BINDINGS}})
                print(f"round {round_id + 1}/{args.rounds}: {label}", flush=True)
        baseline = runs[0]["fixtures"]
        for row in runs:
            if any(row["fixtures"][key]["checksum"] != baseline[key]["checksum"] for key in BINDINGS):
                raise SystemExit("cross-library checksum mismatch; no result published")
        summary = {label: {key: statistics.median(row["fixtures"][key]["median_ns"]
                   for row in runs if row["library"] == label) for key in BINDINGS} for label in labels}
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
                  "runtime_environment": RUNTIME_ENV,
                  "smoke_only": args.iterations <= 2,
                  "limitations": [
                      "Cross-language/runtime successful shared subsets; not feature equivalence or a general performance ranking.",
                      "Native env/CLI fixtures create a fresh snapshot each operation; initialization, registration, parsing, provider loads and three typed getters are timed.",
                      "Environment is exactly three fixture variables plus the explicit Go runtime controls in runtime_environment; builds inherit the ordinary environment.",
                      "Viper BindEnv resolves values lazily through getters; Koanf env/v2 scans os.Environ and materializes a provider map; Goose apply_env eagerly validates declared bindings.",
                      "CLI uses repeated pflag StringArray values without comma splitting, Viper BindPFlags and official Koanf posflag; Goose validates its prepared schema and binding descriptors.",
                      "Reload replays defaults plus three current JSON documents into fresh state, with a 256-item IntegerList replaced in the upper document. Removing the middle port exposes the lower document.",
                      "Goose supplies schema/range/type checks, independently owned i64 lists, atomic validated reload and per-setting sources; adapter paths do not supply these contracts.",
                      "All inputs and layer descriptors are prepared before timing. Default registration and snapshot construction remain timed. No file I/O is timed.",
                      "Each operation checksums port plus list length plus name length. Full final values are checked outside timing; Goose also verifies sources. Checksums must match independently calculated expectations before publication.",
                      "Frequency, thermals and other system load uncontrolled; setup only, no dedicated warmup. One/two-operation records are smoke checks only."],
                  "runs": runs, "median_of_run_medians_ns": summary}
        write_record(args.output, result)
        print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
