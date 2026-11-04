#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Linux memory audit of fixed workloads from one exact source commit.

Each mode/repeat runs in a fresh process. Checkpoint handshakes expose current
process footprint; wait4 reports that child's lifetime high-water RSS. Logical
lengths do not expose allocator capacity, allocation counts or general leaks.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from measure import write_record

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ("config.goose", "toml.goose", "vendor.goose", "bindings.goose",
           "json_layer.goose", "reload.goose")
MODES = {"scalar": 0, "lists": 1, "reload": 2}
MAX_OUTPUT = 1024 * 1024
KEY_BYTES = sum(len(f"field{i}") for i in range(256))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def schedule(mode, cycles):
    if mode == "control":
        return [(0, "initial"), (0, "released")]
    rows = [(0, "initial")]
    for cycle in sorted({1, 10, 100, cycles}):
        if cycle <= cycles:
            rows.extend((cycle, state) for state in
                        (("large", "small", "rejected") if mode == "reload" else ("large", "small")))
    return [*rows, (0, "released")]


def logical(mode, state):
    if state == "released" or mode == "control":
        return dict.fromkeys(("bytes", "items", "keys", "fields"), 0)
    if state == "initial":
        size, items = 0, 0
    elif state == "large":
        size = 256 * 4096 + (1278 if mode == "reload" else 256 * 5)
        items = 255 * 256 if mode == "reload" else 65536 if mode == "lists" else 0
    else:
        size, items = (13, 0) if mode == "reload" else (1280, 0)
    return {"bytes": size, "items": items, "keys": KEY_BYTES, "fields": 256}


def parse_checkpoint(line, expected, mode):
    match = re.fullmatch(rb"MEMORY1 (0|[1-9][0-9]*) (initial|large|small|rejected|released) (0|[1-9][0-9]*) (0|[1-9][0-9]*) (0|[1-9][0-9]*) (0|[1-9][0-9]*)", line)
    if match is None:
        raise ValueError(f"invalid checkpoint: {line[:200]!r}")
    cycle, state = int(match[1]), match[2].decode("ascii")
    if (cycle, state) != expected:
        raise ValueError(f"checkpoint order mismatch: {(cycle, state)} != {expected}")
    actual = dict(zip(("bytes", "items", "keys", "fields"), map(int, match.groups()[2:])))
    if actual != logical(mode, state):
        raise ValueError(f"logical state mismatch: {actual}")
    return {"cycle": cycle, "state": state, "logical_lengths": actual}


def proc_fields(text, names):
    result = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([A-Za-z_]+):\s+(\d+) kB", line)
        if match and match[1] in names:
            if match[1] in result:
                raise ValueError("duplicate /proc metric")
            result[match[1]] = int(match[2])
    if set(result) != set(names):
        raise ValueError(f"missing /proc metrics: {set(names) - result.keys()}")
    return result


def sample_process(pid):
    directory = Path("/proc") / str(pid)
    smaps = proc_fields((directory / "smaps_rollup").read_text(),
                        ("Rss", "Private_Clean", "Private_Dirty", "Private_Hugetlb"))
    status = proc_fields((directory / "status").read_text(), ("VmHWM", "VmSize"))
    return {"rss_kib": smaps["Rss"],
            "private_kib": sum(smaps[key] for key in ("Private_Clean", "Private_Dirty", "Private_Hugetlb")),
            "status_peak_rss_kib": status["VmHWM"],
            "virtual_address_space_kib": status["VmSize"],
            "raw_smaps_kib": smaps, "raw_status_kib": status}


def command_template(command):
    """Keep executable arguments without publishing temporary/workspace paths."""
    if command[0] == "taskset":
        return [*command[:3], "<binary>", *command[4:]]
    return ["<binary>", *command[1:]]


def normalized_diagnostics(data, workspace, compiler):
    """Normalize known private paths; raw byte hashes retain diagnostic identity."""
    return (data.decode(errors="backslashreplace")
            .replace(str(compiler), "<compiler>")
            .replace(str(workspace), "<workspace>"))


def run_child(command, mode, cycles, environment, cwd, timeout):
    """Bounded protocol; wait4 only consumes this direct Popen PID's status.

    Popen.poll/wait/communicate are unused: they would consume wait status before
    wait4 returns per-child rusage. Cleanup kills the process group and reaps.
    """
    started = time.monotonic()
    parent_launch = proc_fields(Path("/proc/self/status").read_text(), ("VmRSS", "VmHWM"))
    process = subprocess.Popen(command, cwd=cwd, env=environment, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True, bufsize=0)
    rows, raw_stdout, raw_stderr = [], bytearray(), bytearray()
    pending = bytearray()
    expected = schedule(mode, cycles)
    done = False
    reaped = False
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            while selector.get_map():
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    raise TimeoutError("memory child exceeded timeout")
                for key, _ in selector.select(min(remaining, 0.2)):
                    chunk = os.read(key.fileobj.fileno(), 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    target = raw_stdout if key.data == "stdout" else raw_stderr
                    target.extend(chunk)
                    if len(target) > MAX_OUTPUT:
                        raise ValueError("memory child output exceeded limit")
                    if key.data == "stderr":
                        continue
                    pending.extend(chunk)
                    if len(pending) > 4096:
                        raise ValueError("memory child line exceeded limit")
                    while b"\n" in pending:
                        line, _, tail = pending.partition(b"\n")
                        pending[:] = tail
                        if done:
                            raise ValueError("output after DONE1")
                        if len(rows) == len(expected):
                            if line != b"DONE1":
                                raise ValueError("missing DONE1")
                            done = True
                            process.stdin.close()
                        else:
                            row = parse_checkpoint(bytes(line), expected[len(rows)], mode)
                            row["process"] = sample_process(process.pid)
                            rows.append(row)
                            process.stdin.write(b"continue\n")
            if pending or not done:
                raise ValueError("truncated memory child protocol")
        while True:
            pid, status, usage = os.wait4(process.pid, os.WNOHANG)
            if pid:
                reaped = True
                process.returncode = os.waitstatus_to_exitcode(status)
                break
            if time.monotonic() - started >= timeout:
                raise TimeoutError("memory child did not exit")
            time.sleep(0.01)
        if process.returncode != 0:
            raise ValueError(f"memory child exited {process.returncode}")
        return {"command": command_template(command), "pid": process.pid, "parent_launch_status_kib": parent_launch,
                "checkpoints": rows, "peak_rss_kib": usage.ru_maxrss,
                "peak_method": "Linux wait4 ru_maxrss for direct Popen PID",
                "elapsed_seconds": time.monotonic() - started,
                "stdout": raw_stdout.decode("utf-8", errors="strict"),
                "stderr": raw_stderr.decode("utf-8", errors="backslashreplace")}
    except Exception as error:
        raise RuntimeError(f"{error}; stderr={bytes(raw_stderr)!r}") from error
    finally:
        if not reaped:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            _, status, _ = os.wait4(process.pid, 0)
            process.returncode = os.waitstatus_to_exitcode(status)
        for stream in (process.stdin, process.stdout, process.stderr):
            stream.close()


def command_output(command, environment, cwd):
    return subprocess.run(command, cwd=cwd, env=environment, capture_output=True,
                          check=True, timeout=120).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--goose", type=Path, required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--cycles", type=int, default=100)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--mode", choices=("all", *MODES), default="all")
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.cycles <= 1000 or not 1 <= args.repeats <= 20 or not 1 <= args.timeout <= 600:
        parser.error("cycles must be 1..1000, repeats 1..20, timeout 1..600 seconds")
    if not hasattr(os, "wait4") or not Path("/proc/self/smaps_rollup").exists():
        parser.error("Linux /proc smaps_rollup and wait4 are required")
    if args.cpu is not None and args.cpu not in os.sched_getaffinity(0):
        parser.error("CPU is outside this process's affinity")
    compiler = args.goose.resolve(strict=True)
    harness = (ROOT / "bench/memory.goose").read_bytes()
    driver_hash = sha(Path(__file__).read_bytes())
    writer_hash = sha((ROOT / "bench/measure.py").read_bytes())
    parent = ROOT / ".build/memory"
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="run-", dir=parent) as temporary:
        workspace = Path(temporary)
        goose_home = workspace / "goose-home"
        goose_home.mkdir()
        # HOME is inherited unchanged. Goose state is private, and ambient
        # credential/configuration variables are not copied into the child.
        environment = {"PATH": os.environ.get("PATH", os.defpath), "LANG": "C.UTF-8",
                       "TZ": "UTC", "GOOSE_HOME": str(goose_home)}
        if "HOME" in os.environ:
            environment["HOME"] = os.environ["HOME"]
        output = lambda command: command_output(command, environment, ROOT)
        revision = output(["git", "rev-parse", "--verify", f"{args.ref}^{{commit}}"]).decode().strip()
        pin = output(["git", "show", f"{revision}:GOOSE_REVISION"]).decode().strip()
        version = output([str(compiler), "--version"]).decode().strip()
        if not re.fullmatch(r"[0-9a-f]{40}", pin) or not version.startswith(f"goose {pin[:7]} "):
            parser.error("provided compiler does not match the source compiler pin")
        gcc_path = Path(shutil.which("gcc", path=environment["PATH"])).resolve()
        toolchain_inputs = {}
        for relative in ("stdlib/std.goose", "stdlib/os.goose"):
            path = compiler.parent.parent / relative
            if path.is_file():
                toolchain_inputs[relative] = sha(path.read_bytes())
        compiler_hash = sha(compiler.read_bytes())
        gcc_hash = sha(gcc_path.read_bytes())
        snapshot = workspace / "snapshot"
        snapshot.mkdir()
        hashes = {}
        for name in SOURCES:
            data = output(["git", "show", f"{revision}:{name}"])
            (snapshot / name).write_bytes(data)
            hashes[name] = sha(data)
        (snapshot / "bench").mkdir()
        source = snapshot / "bench/memory.goose"
        source.write_bytes(harness)
        binary = snapshot / "memory"
        build_command = [str(compiler), "build", str(source), "--cc", "gcc", "-O2", "-o", str(binary)]
        build = subprocess.run(build_command, cwd=workspace, env=environment, capture_output=True,
                               timeout=120)
        if build.returncode:
            raise RuntimeError(f"build exited {build.returncode}: {build.stderr.decode(errors='backslashreplace')} {build.stdout.decode(errors='backslashreplace')}")
        modes = tuple(MODES) if args.mode == "all" else (args.mode,)
        measurement_started = datetime.now(timezone.utc).isoformat()
        measurements = []
        controls = []
        for repeat in range(args.repeats):
            control_command = [str(binary), "3", "1"]
            if args.cpu is not None:
                control_command = ["taskset", "-c", str(args.cpu), *control_command]
            controls.append({"repeat": repeat + 1, **run_child(control_command, "control", 1,
                             environment, workspace, args.timeout)})
            for mode in modes:
                command = [str(binary), str(MODES[mode]), str(args.cycles)]
                if args.cpu is not None:
                    command = ["taskset", "-c", str(args.cpu), *command]
                result = run_child(command, mode, args.cycles, environment, workspace, args.timeout)
                measurements.append({"repeat": repeat + 1, "mode": mode, **result})
                print(f"Measured memory repeat {repeat + 1}/{args.repeats}: {mode}", flush=True)
        measurement_finished = datetime.now(timezone.utc).isoformat()
        cpu_model = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                          if line.startswith("model name")), "unknown")
        record = {"recorded_utc": datetime.now(timezone.utc).isoformat(), "revision": revision,
                  "measurement_started_utc": measurement_started, "measurement_finished_utc": measurement_finished,
                  "source_sha256": hashes, "compiler_revision": pin, "compiler_version": version,
                  "compiler_sha256": compiler_hash, "binary_sha256": sha(binary.read_bytes()),
                  "harness_sha256": sha(harness), "driver_sha256": driver_hash,
                  "record_writer_sha256": writer_hash,
                  "build_command": ["<compiler>", "build", "<snapshot>/bench/memory.goose", "--cc", "gcc", "-O2", "-o", "<binary>"],
                  "build_stdout": normalized_diagnostics(build.stdout, workspace, compiler),
                  "build_stderr": normalized_diagnostics(build.stderr, workspace, compiler),
                  "diagnostics_paths_normalized": True,
                  "build_diagnostics_raw_sha256": {"stdout": sha(build.stdout), "stderr": sha(build.stderr)},
                  "gcc_version": output(["gcc", "--version"]).decode().splitlines()[0],
                  "gcc_executable": "gcc", "gcc_sha256": gcc_hash,
                  "toolchain_input_sha256": toolchain_inputs, "python_version": sys.version,
                  "cpu_model": cpu_model,
                  "platform": {key: getattr(os.uname(), key) for key in ("sysname", "release", "version", "machine")},
                  "cycles": args.cycles, "repeats": args.repeats, "modes": modes,
                  "cpu_affinity": args.cpu, "inherited_affinity": sorted(os.sched_getaffinity(0)),
                  "metric_units": "KiB for process memory; bytes/items/keys/fields are logical lengths",
                  "limitations": ["RSS/private/peak include runtime, fixture inputs, getter checks and harness overhead",
                                  "initial checkpoint includes schema/store setup and fixed prebuilt input fixtures",
                                  "released checkpoint follows scenario owner teardown; physical high-water storage can remain",
                                  "logical lengths do not expose retained builder capacity or runtime stack high-water storage",
                                  "VmSize is virtual address-space size including reservations, not memory consumption",
                                  "status VmHWM is approximate; wait4 is reported lifetime child high-water RSS",
                                  "wait4 can include inherited pre-exec launcher RSS; same-binary controls omit scenario setup; parent launch RSS is recorded; do not subtract controls mechanically",
                                  "no trim_memory or allocator instrumentation; no claim of allocation counts or general leak freedom",
                                  "frequency, thermal state and unrelated host load are uncontrolled"],
                  "launcher_controls": controls, "measurements": measurements}
        write_record(args.output, record)
        print(f"Saved {len(measurements)} fresh-process runs to {args.output}")


if __name__ == "__main__":
    main()
