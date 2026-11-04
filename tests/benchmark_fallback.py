#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check diagnostic order, counter validation and failure-safe records."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bench/diagnostics/fallback_controls.py"


class FallbackControlsTests(unittest.TestCase):
    def load(self, directory):
        argv = [str(SCRIPT), "--root", str(ROOT), "--workdir", str(directory)]
        with mock.patch.object(sys, "argv", argv):
            return runpy.run_path(str(SCRIPT), run_name="fallback_test")

    def prepared(self, directory):
        directory = Path(directory)
        snapshots = {}
        for label in ("baseline", "candidate", "candidate-copy"):
            folder = directory / label
            (folder / "bench").mkdir(parents=True)
            names = ("config.goose", "toml.goose", "vendor.goose", "bench/bench.goose")
            for name in (*names, "benchmark"):
                (folder / name).write_bytes(name.encode())
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            snapshots[label] = {"source_sha256": {name: digest(folder / name) for name in names},
                                "binary_sha256": digest(folder / "benchmark")}
        (directory / "manifest.json").write_text(json.dumps({"snapshots": snapshots}))

    def test_opposite_physical_order_and_mapping(self):
        with tempfile.TemporaryDirectory() as directory:
            self.prepared(directory)
            module = self.load(directory)
            state = module["series"].__globals__
            output = "\n".join(f"{name} samples_ns=[1,1,1,1,1,1,1] checksum=1"
                               for name in state["measure"].UPDATE_FIXTURE_NAMES)
            for control, expected in (
                ("ab", ["baseline", "candidate", "candidate", "baseline"]),
                ("ba-labels", ["candidate", "baseline", "baseline", "candidate"]),
                ("same-binary", ["candidate"] * 4),
            ):
                executed = []

                def fake(command, **kwargs):
                    executed.append(Path(command[-2]).parent.name)
                    return SimpleNamespace(stdout=output, stderr="")

                args = SimpleNamespace(control=control, pairs=2, reverse=False,
                                       count=1, perf=False, instrumented=False,
                                       output="record.json")
                with mock.patch.dict(state, cmd=fake), \
                        contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(module["series"](args), 0)
                self.assertEqual(executed, expected)
                record = json.loads((Path(directory) / "record.json").read_text())
                self.assertEqual(record["mapping"]["left"], expected[0])
                self.assertEqual(len(record["records"]), 4)

    def test_counter_sequence_and_positive_events(self):
        with tempfile.TemporaryDirectory() as directory:
            parse = self.load(directory)["parse_counters"]
            rows = [f"FC sample={i} bytes=2 calls=1 cycles=20 instructions=10 enabled=100 running=100" for i in range(42)]
            text = "\n".join(rows)
            self.assertEqual(len(parse(text)), 42)
            for bad in ("\n".join(rows[1:]), text + "\n" + rows[-1],
                        text.replace("sample=1 ", "sample=0 "),
                        text.replace("cycles=20", "cycles=0"),
                        text.replace("instructions=10", "instructions=0"),
                        text.replace("running=100", "running=99"),
                        text.replace("enabled=100 running=100", "enabled=0 running=0"),
                        text.replace("bytes=2", "bytes=-2")):
                with self.subTest(bad=bad), self.assertRaises(ValueError):
                    parse(bad)

    def test_changed_binary_and_source_rejected_before_execution(self):
        for name in ("benchmark", "config.goose"):
            with tempfile.TemporaryDirectory() as directory:
                self.prepared(directory)
                module = self.load(directory)
                (Path(directory) / "candidate" / name).write_bytes(b"changed")
                args = SimpleNamespace(control="ab", instrumented=False)
                with mock.patch.dict(module["series"].__globals__, cmd=mock.Mock()) as state:
                    with self.assertRaisesRegex(ValueError, "hash mismatch"):
                        module["series"](args)
                    state["cmd"].assert_not_called()
                self.assertFalse((Path(directory) / "record.json").exists())

    def test_prepare_rejects_reused_workdir_before_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            self.prepared(directory)
            module = self.load(directory)
            module["settings"].goose = Path("/compiler")
            before = (Path(directory) / "manifest.json").read_bytes()
            with self.assertRaisesRegex(SystemExit, "empty workdir"):
                module["prepare"]()
            self.assertEqual((Path(directory) / "manifest.json").read_bytes(), before)

    def test_failed_instrument_build_invalidates_old_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            self.prepared(directory)
            prior = Path(directory) / "instrumentation-manifest.json"
            prior.write_text('{"old":true}')
            result = subprocess.run([sys.executable, str(SCRIPT.with_name("instrument_fallback.py")),
                                     "--workdir", directory], capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(prior.exists())
            self.assertFalse((Path(directory) / ".active.lock").exists())

    def test_failed_serialization_preserves_record(self):
        with tempfile.TemporaryDirectory() as directory:
            module = self.load(directory)
            path = Path(directory) / "record.json"
            path.write_text('{"prior":true}\n')
            with self.assertRaises(ValueError):
                module["dump"](path, {"bad": float("nan")})
            self.assertEqual(path.read_text(), '{"prior":true}\n')
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), ["record.json"])

    def test_commands_have_default_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            module = self.load(directory)
            with mock.patch.object(subprocess, "Popen") as popen:
                popen.return_value.communicate.return_value = ("output", "")
                popen.return_value.returncode = 0
                module["cmd"](["tool"])
                popen.return_value.communicate.assert_called_once_with(timeout=120)
                self.assertTrue(popen.call_args.kwargs["start_new_session"])

    def test_command_timeout_kills_own_group_and_reaps(self):
        with tempfile.TemporaryDirectory() as directory:
            module = self.load(directory)
            process = mock.Mock(pid=12345)
            process.communicate.side_effect = [subprocess.TimeoutExpired(["tool"], 1), ("", "")]
            with mock.patch.object(subprocess, "Popen", return_value=process), \
                    mock.patch.object(os, "killpg") as kill:
                with self.assertRaises(subprocess.TimeoutExpired):
                    module["cmd"](["tool"], timeout=1)
                kill.assert_called_once_with(12345, module["signal"].SIGKILL)
                self.assertEqual(process.communicate.call_count, 2)

    def test_provenance_failure_has_distinct_exit_from_timing_alarm(self):
        with tempfile.TemporaryDirectory() as directory:
            self.prepared(directory)
            (Path(directory) / "candidate/benchmark").write_bytes(b"changed")
            cpu = str(min(os.sched_getaffinity(0)))
            result = subprocess.run([sys.executable, str(SCRIPT), "--root", str(ROOT),
                                     "--workdir", directory, "--cpu", cpu, "--build-cpu", cpu,
                                     "--control", "ab"], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"hash mismatch", result.stderr)
            self.assertFalse((Path(directory) / "record.json").exists())

    def test_invalid_counts_and_missing_control_fail_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            cpu = str(min(os.sched_getaffinity(0)))
            base = [sys.executable, str(SCRIPT), "--root", str(ROOT),
                    "--workdir", directory, "--cpu", cpu, "--build-cpu", cpu]
            for extra in (["--count", "0"], ["--pairs", "21"], []):
                result = subprocess.run([*base, *extra], capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 2)
                self.assertIn(b"error:", result.stderr)


if __name__ == "__main__":
    unittest.main()
