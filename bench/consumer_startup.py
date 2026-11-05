#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Measure frozen goose-check invocations, with identical-binary controls."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import selectors
import shutil
import signal
import statistics
import subprocess
import tempfile
import time

from measure import write_record

ROOT = Path(__file__).resolve().parents[1]
BEFORE = "3dae6984941ed2ba97817d34c17722a03de6d62f"
AFTER = "32de6c4783bf8d3242e042993dadd160a98b2945"
LIMITS = {"expect_exit": 0, "timeout_ms": 30000, "output_limit": 65536}
MAX_EXPORT_FILES = 256
MAX_BLOB_BYTES = 2 * 1024 * 1024
MAX_EXPORT_BYTES = 16 * 1024 * 1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def execute(command, *, cwd, env, timeout=120, budget=65536):
    """Bound output and lifetime; retain/reap the private process-group leader."""
    started = time.perf_counter_ns()
    child = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=True)
    deadline = time.monotonic() + timeout
    buffers = {child.stdout: bytearray(), child.stderr: bytearray()}
    try:
        with selectors.DefaultSelector() as reader:
            for stream in buffers:
                reader.register(stream, selectors.EVENT_READ)
            while reader.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("consumer subprocess deadline exceeded")
                for key, _ in reader.select(remaining):
                    chunk = os.read(key.fileobj.fileno(), 4096)
                    if not chunk:
                        reader.unregister(key.fileobj)
                    else:
                        buffers[key.fileobj].extend(chunk)
                        if sum(map(len, buffers.values())) > budget:
                            raise ValueError("consumer subprocess output budget exceeded")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("consumer subprocess deadline exceeded")
        code = child.wait(timeout=remaining)
        elapsed = time.perf_counter_ns() - started
        return code, bytes(buffers[child.stdout]), bytes(buffers[child.stderr]), elapsed
    except BaseException:
        # No earlier poll/wait reaped this leader on the failure path.
        if child.returncode is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=15)
        raise
    finally:
        child.stdout.close()
        child.stderr.close()


def checked(command, *, cwd, env, timeout=120, budget=65536):
    code, out, error, _ = execute(command, cwd=cwd, env=env, timeout=timeout, budget=budget)
    if code:
        raise RuntimeError(f"build/provenance command failed: {error.decode(errors='replace')}")
    return out


def export(consumer, ref, destination):
    git_env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "C",
               "GIT_NO_REPLACE_OBJECTS": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
    revision = checked(["git", "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}"],
                       cwd=consumer, timeout=30, env=git_env).decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("invalid resolved Git revision")
    entries = list(filter(None, checked(["git", "ls-tree", "-rz", revision], cwd=consumer,
                                       timeout=30, env=git_env, budget=1024 * 1024).split(b"\0")))
    if len(entries) > MAX_EXPORT_FILES:
        raise ValueError("consumer export file count exceeded")
    hashes = {}
    total = 0
    destination.mkdir()
    for entry in entries:
        metadata, raw_name = entry.split(b"\t", 1)
        mode, kind, object_id = metadata.split()
        name = Path(raw_name.decode("utf-8"))
        if kind != b"blob" or mode not in (b"100644", b"100755") or name.is_absolute() or ".." in name.parts:
            raise ValueError("unsupported or unsafe consumer Git tree entry")
        data = checked(["git", "cat-file", "blob", object_id.decode()], cwd=consumer,
                       timeout=30, env=git_env, budget=min(MAX_BLOB_BYTES, MAX_EXPORT_BYTES - total))
        total += len(data)
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(0o755 if mode == b"100755" else 0o644)
        hashes[name.as_posix()] = sha(data)
    return revision, hashes


def profile(snapshot):
    pins = json.loads((snapshot / "vendor/pins.json").read_text())
    expected = {"pins.json"}
    for name, entry in pins.items():
        for filename, digest in entry["sha256"].items():
            relative = Path(name) / filename
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("unsafe vendor inventory path")
            source = snapshot / "vendor" / relative
            if not source.is_file() or sha(source.read_bytes()) != digest:
                raise ValueError("vendor inventory mismatch")
            expected.add(relative.as_posix())
    actual = {p.relative_to(snapshot / "vendor").as_posix()
              for p in (snapshot / "vendor").rglob("*") if p.is_file()}
    if actual != expected:
        raise ValueError("vendor inventory file set differs")
    native = {p.relative_to(snapshot).as_posix(): sha(p.read_bytes())
              for p in (snapshot / "native").rglob("*") if p.is_file()}
    return {"native": native, "process": pins["goose-process"], "fs": pins["goose-fs"],
            "manifest": sha((snapshot / "check.build").read_bytes()),
            "wrapper": sha((snapshot / "scripts/compiler.py").read_bytes())}


def normalized(value, replacements):
    if isinstance(value, str):
        for actual, replacement in replacements:
            value = value.replace(actual, replacement)
        return value
    if isinstance(value, list):
        return [normalized(item, replacements) for item in value]
    if isinstance(value, dict):
        return {normalized(key, replacements): normalized(item, replacements) for key, item in value.items()}
    return value


def fixture_commands(workspace, binaries):
    commands = {}
    for label, binary in (("before", binaries["before"]),
                          ("current-A", binaries["after"]), ("current-B", binaries["after"])):
        commands[label + "-no-file"] = [str(binary), "--", "/bin/true"]
        commands[label + "-help"] = [str(binary), "--help"]
    fixtures = {}
    for extension, body in (("json", json.dumps(LIMITS, separators=(",", ":")).encode()),
                            ("toml", b"expect_exit=0\ntimeout_ms=30000\noutput_limit=65536\n")):
        for size in ("small", "64k"):
            data = body if size == "small" else body + b" " * (65536 - len(body))
            path = workspace / (size + "." + extension)
            path.write_bytes(data)
            fixtures[path.name] = {"sha256": sha(data), "bytes": len(data)}
            commands[extension + "-" + size] = [str(binaries["after"]), "--config", str(path), "--", "/bin/true"]
    commands["json-cli"] = [str(binaries["after"]), "--config", str(workspace / "small.json"),
                            "--expect-exit", "0", "--timeout-ms", "30000", "--output-limit", "65536", "--", "/bin/true"]
    return commands, fixtures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--consumer", type=Path, required=True)
    parser.add_argument("--goose", type=Path, required=True)
    parser.add_argument("--before-ref", default=BEFORE)
    parser.add_argument("--after-ref", default=AFTER)
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--samples", type=int, default=16)
    parser.add_argument("--seed", type=int, default=606)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 40 or not 1 <= args.samples <= 32:
        parser.error("rounds must be 1..40 and samples 1..32")
    inherited = sorted(os.sched_getaffinity(0))
    if args.cpu not in inherited:
        parser.error("CPU is outside this process's affinity")
    os.sched_setaffinity(0, {args.cpu})
    compiler = args.goose.resolve(strict=True)
    consumer = args.consumer.resolve(strict=True)
    gcc = Path(shutil.which("gcc") or "gcc").resolve(strict=True)
    compiler_hash, gcc_hash = sha(compiler.read_bytes()), sha(gcc.read_bytes())
    true_path = Path("/bin/true").resolve(strict=True)
    true_hash = sha(true_path.read_bytes())
    driver_hash = sha(Path(__file__).read_bytes())
    writer_hash = sha((ROOT / "bench/measure.py").read_bytes())
    parent = ROOT / ".build/consumer-startup"
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="run with spaces ", dir=parent) as temporary:
        workspace = Path(temporary)
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "C", "TZ": "UTC",
               "GOOSE_HOME": str(workspace / "goose-home")}
        if "HOME" in os.environ:
            env["HOME"] = os.environ["HOME"]
        compiler_version = checked([str(compiler), "version"], cwd=workspace, env=env).decode().strip()
        stdlib = compiler.parent.parent / "stdlib"
        if not stdlib.is_dir():
            raise ValueError("use the pinned compiler build with its adjacent stdlib sources")
        toolchain_inputs = {p.relative_to(stdlib).as_posix(): sha(p.read_bytes())
                            for p in stdlib.rglob("*.goose")}
        snapshots, binaries, profiles = {}, {}, []
        pins = []
        for label, ref, directory in (("before", args.before_ref, "before"), ("after", args.after_ref, "after_")):
            snapshot = workspace / directory
            revision, hashes = export(consumer, ref, snapshot)
            profiles.append(profile(snapshot))
            pins.append((snapshot / "GOOSE_REVISION").read_text().strip())
            if len(profiles) == 2 and (profiles[0] != profiles[1] or pins[0] != pins[1]):
                raise ValueError("native/wrapper/dependency/compiler profiles differ")
            if not re.fullmatch(r"[0-9a-f]{40}", pins[-1]) or not compiler_version.startswith("goose " + pins[-1][:7] + " "):
                raise ValueError("compiler does not match consumer pin")
            wrapper = checked(["python3", "scripts/compiler.py", "--cc", str(gcc)], cwd=snapshot, env=env).decode().strip()
            c_before = set((workspace / "goose-home/build/prog").glob("*/check.c"))
            binary = snapshot / "checker"
            command = [str(compiler), "build", str(snapshot / "check.goose"), "--cc", wrapper, "-O2", "-o", str(binary)]
            code, out, error, _ = execute(command, cwd=snapshot, env=env)
            if code:
                raise RuntimeError("consumer build failed: " + error.decode(errors="replace"))
            generated = set((workspace / "goose-home/build/prog").glob("*/check.c")) - c_before
            if len(generated) != 1:
                raise ValueError("expected exactly one generated consumer C file")
            generated_bytes = generated.pop().read_bytes()
            calls = re.findall(rb"gs_rt_init\(argc, argv, (\d+), (\d+), (\d+)\);", generated_bytes)
            if len(calls) != 1:
                raise ValueError("unrecognized runtime initialization")
            snapshots[label] = {"revision": revision, "source_sha256": hashes,
                                "binary_sha256": sha(binary.read_bytes()), "binary_bytes": binary.stat().st_size,
                                "generated_c_sha256": sha(generated_bytes),
                                "runtime_init": dict(zip(("main_stack_count", "main_region_bound", "worker_region_bound"), map(int, calls[0]))),
                                "build_command": command, "build_stdout": out.decode(), "build_stderr": error.decode(),
                                "build_diagnostics_raw_sha256": {"stdout": sha(out), "stderr": sha(error)},
                                "compiler_wrapper_sha256": sha(Path(wrapper).read_bytes())}
            binaries[label] = binary
        commands, fixtures = fixture_commands(workspace, binaries)
        expected = {}
        measurement_env = {key: env[key] for key in ("PATH", "LANG", "TZ")}
        for name, command in commands.items():
            code, out, error, _ = execute(command, cwd=workspace, env=measurement_env, timeout=5)
            if code or out or (not name.endswith("help") and error) or (name.endswith("help") and not error.startswith(b"usage: goose-check ")):
                raise ValueError("consumer fixture preflight failed")
            expected[name] = (code, out, error)
            for _ in range(2):
                actual = execute(command, cwd=workspace, env=measurement_env, timeout=5)
                if actual[:3] != expected[name]:
                    raise ValueError("consumer warmup changed behavior")
        started = datetime.now(timezone.utc).isoformat()
        records = []
        rng = random.Random(args.seed)
        for iteration in range(args.rounds):
            order = list(commands)
            rng.shuffle(order)
            for name in order:
                samples = []
                for _ in range(args.samples):
                    result = execute(commands[name], cwd=workspace, env=measurement_env, timeout=5)
                    if result[:3] != expected[name] or result[3] <= 0:
                        raise ValueError("consumer sample changed behavior or clock")
                    samples.append(result[3])
                records.append({"round": iteration, "case": name, "samples_ns": samples,
                                "median_ns": statistics.median(samples)})
        finished = datetime.now(timezone.utc).isoformat()
        for label, binary in binaries.items():
            if sha(binary.read_bytes()) != snapshots[label]["binary_sha256"]:
                raise ValueError("measured binary changed")
            snapshot = binary.parent
            for name, digest in snapshots[label]["source_sha256"].items():
                if sha((snapshot / name).read_bytes()) != digest:
                    raise ValueError("frozen source changed")
        for name, fixture in fixtures.items():
            if sha((workspace / name).read_bytes()) != fixture["sha256"]:
                raise ValueError("measured fixture changed")
        if sha(compiler.read_bytes()) != compiler_hash or sha(gcc.read_bytes()) != gcc_hash:
            raise ValueError("compiler changed")
        if Path("/bin/true").resolve(strict=True) != true_path or sha(true_path.read_bytes()) != true_hash:
            raise ValueError("invoked /bin/true changed")
        if {p.relative_to(stdlib).as_posix(): sha(p.read_bytes()) for p in stdlib.rglob("*.goose")} != toolchain_inputs:
            raise ValueError("compiler standard library changed")
        if sha(Path(__file__).read_bytes()) != driver_hash or sha((ROOT / "bench/measure.py").read_bytes()) != writer_hash:
            raise ValueError("measurement tools changed")
        cpu_model = "unknown"
        for block in Path("/proc/cpuinfo").read_text().split("\n\n"):
            fields = {key.strip(): value.strip() for key, value in
                      (line.split(":", 1) for line in block.splitlines() if ":" in line)}
            if fields.get("processor") == str(args.cpu):
                cpu_model = fields.get("model name", "unknown")
                break
        summary = {name: statistics.median(row["median_ns"] for row in records if row["case"] == name) for name in commands}
        result = {"started_utc": started, "finished_utc": finished, "cpu_affinity": sorted(os.sched_getaffinity(0)),
                  "inherited_affinity": inherited, "platform": platform.platform(), "python_version": platform.python_version(),
                  "cpu_model": cpu_model, "frequency_governor": "uncontrolled", "aslr": "uncontrolled",
                  "compiler_revision": pins[0], "compiler_version": compiler_version, "compiler_sha256": compiler_hash,
                  "gcc_version": checked([str(gcc), "--version"], cwd=workspace, env=env).decode().splitlines()[0], "gcc_sha256": gcc_hash,
                  "toolchain_input_sha256": toolchain_inputs,
                  "true_executable": {"path": str(true_path), "sha256": true_hash},
                  "driver_sha256": driver_hash, "record_writer_sha256": writer_hash,
                  "rounds": args.rounds, "samples_per_case": args.samples, "seed": args.seed, "warmups_per_case": 3,
                  "snapshots": snapshots, "matched_native_profile": profiles[0], "fixtures": fixtures,
                  "commands": commands, "expected_outputs": {name: {"exit": value[0], "stdout": value[1].decode(), "stderr": value[2].decode()} for name, value in expected.items()},
                  "effective_limits": LIMITS, "records": records, "summary_ns": summary,
                  "environment_policy": {"build_keys": sorted(env), "measurement_keys": sorted(measurement_env),
                                         "HOME": "inherited unchanged when present", "Git": "ambient config variables and replacement objects disabled"},
                  "limitations": ["whole Python-controller invocation, including process creation, pipe collection and reaping",
                                  "warm filesystem cache; shared host; no exclusive isolation, frequency or thermal control",
                                  "A/A labels use exactly the same binary; ratios do not isolate loader, mapping or parser costs",
                                  "dynamic libraries and GCC subprograms are not hashed; the complete host is not frozen",
                                  "successful cases rely on the pinned program's direct-child cleanup; failure paths kill the runner's private group",
                                  "runtime counts are virtual data-stack regions, not resident RAM or allocations"]}
        # Replace only known local path prefixes; keep all hashes and numbers.
        replacements = ((str(compiler), "<GOOSE>"), (str(gcc), "<GCC>"), (str(workspace), "<ARTIFACTS>"))
        write_record(args.output, normalized(result, replacements))
        print("checked consumer startup record:", args.output, flush=True)


if __name__ == "__main__":
    main()
