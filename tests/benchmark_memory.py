#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Protocol, direct-child accounting and immutable-source memory regressions."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bench"))
spec = importlib.util.spec_from_file_location("memory_measure", ROOT / "bench/measure_memory.py")
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


def row(cycle, state, mode="scalar"):
    lengths = measure.logical(mode, state)
    return f"MEMORY1 {cycle} {state} " + " ".join(str(lengths[key]) for key in ("bytes", "items", "keys", "fields"))


def program(mode="scalar", cycles=1, suffix=""):
    lines = [row(cycle, state, mode) for cycle, state in measure.schedule(mode, cycles)]
    return ("import sys\n"
            f"for line in {lines!r}:\n"
            " print(line, flush=True)\n"
            " assert sys.stdin.readline() == 'continue\\n'\n"
            "print('DONE1', flush=True)\n" + suffix)


class MemoryProtocolTests(unittest.TestCase):
    def test_build_diagnostics_normalize_only_known_paths_and_preserve_numbers(self):
        raw = b"built /private/work/snapshot/memory using /private/tool/goose; 1049856 bytes\n"
        self.assertEqual(measure.normalized_diagnostics(raw, Path("/private/work"), Path("/private/tool/goose")),
                         "built <workspace>/snapshot/memory using <compiler>; 1049856 bytes\n")

    def test_command_templates_keep_flags_and_omit_executable_paths(self):
        self.assertEqual(measure.command_template(["/private/run/memory", "2", "100"]),
                         ["<binary>", "2", "100"])
        self.assertEqual(measure.command_template(["taskset", "-c", "6", "/private/run/memory", "2", "100"]),
                         ["taskset", "-c", "6", "<binary>", "2", "100"])

    def test_fixed_logical_lengths_and_released_zero(self):
        self.assertEqual(measure.logical("scalar", "large"),
                         {"bytes": 1049856, "items": 0, "keys": 1938, "fields": 256})
        self.assertEqual(measure.logical("lists", "large")["items"], 65536)
        self.assertEqual(measure.logical("lists", "small")["bytes"], 1280)
        self.assertEqual(measure.logical("reload", "large"),
                         {"bytes": 1049854, "items": 65280, "keys": 1938, "fields": 256})
        self.assertEqual(measure.logical("reload", "rejected")["bytes"], 13)
        self.assertEqual(set(measure.logical("scalar", "released").values()), {0})

    def test_schedule_first_decades_final_no_duplicates(self):
        self.assertEqual(measure.schedule("control", 1), [(0, "initial"), (0, "released")])
        self.assertEqual(measure.schedule("scalar", 1),
                         [(0, "initial"), (1, "large"), (1, "small"), (0, "released")])
        rows = measure.schedule("reload", 101)
        self.assertEqual([cycle for cycle, state in rows if state == "large"], [1, 10, 100, 101])
        self.assertEqual(len(rows), len(set(rows)))

    def test_rejects_wrong_values_order_and_spelling(self):
        valid = row(1, "large").encode()
        self.assertEqual(measure.parse_checkpoint(valid, (1, "large"), "scalar")["cycle"], 1)
        for bad in (valid + b" ", valid.replace(b"1049856", b"1049855"),
                    valid.replace(b" 1 ", b" 01 "), b"log: " + valid,
                    valid.replace(b"1938", b"-1"), valid.replace(b"large", b"small")):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                measure.parse_checkpoint(bad, (1, "large"), "scalar")
        with self.assertRaises(ValueError):
            measure.parse_checkpoint(valid, (10, "large"), "scalar")

    def test_proc_zero_exact_units_unique_presence(self):
        self.assertEqual(measure.proc_fields("Rss: 0 kB\nOther: 9 kB", ["Rss"]), {"Rss": 0})
        for text in ("Rss: 3 MB", "Rss: -1 kB", "Rss: 1 kB\nRss: 2 kB", "Other: 1 kB"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                measure.proc_fields(text, ["Rss"])

    def test_smaps_current_and_status_separate_units(self):
        smaps = "Rss: 100 kB\nPrivate_Clean: 2 kB\nPrivate_Dirty: 9 kB\nPrivate_Hugetlb: 0 kB\n"
        paths = []
        def read(path):
            paths.append(str(path))
            return smaps if path.name == "smaps_rollup" else "VmHWM: 110 kB\nVmSize: 999999 kB\n"
        with mock.patch.object(Path, "read_text", read):
            sample = measure.sample_process(12345)
        self.assertEqual(paths, ["/proc/12345/smaps_rollup", "/proc/12345/status"])
        self.assertEqual(sample["rss_kib"], 100)
        self.assertEqual(sample["private_kib"], 11)
        self.assertEqual(sample["status_peak_rss_kib"], 110)
        self.assertEqual(sample["virtual_address_space_kib"], 999999)

    def child(self, source, timeout=2):
        return measure.run_child([sys.executable, "-c", source], "scalar", 1,
                                 dict(os.environ), ROOT, timeout)

    def test_handshake_direct_pid_peak_and_raw_stderr(self):
        sampled = []
        original = measure.sample_process
        def sample(pid):
            sampled.append(pid)
            return original(pid)
        with mock.patch.object(measure, "sample_process", side_effect=sample):
            result = self.child(program(suffix="sys.stderr.write('raw stderr\\n')\n"))
        self.assertEqual(len(sampled), 4)
        self.assertEqual(len(set(sampled)), 1)
        with self.assertRaises(ChildProcessError):
            os.waitpid(sampled[0], os.WNOHANG)
        self.assertEqual(result["stderr"], "raw stderr\n")
        self.assertEqual(result["pid"], sampled[0])
        self.assertEqual(set(result["parent_launch_status_kib"]), {"VmRSS", "VmHWM"})
        self.assertGreater(result["peak_rss_kib"], 0)
        self.assertEqual(len(result["checkpoints"]), 4)

    def test_nonzero_truncated_extra_malformed_rejected(self):
        for source in (program(suffix="raise SystemExit(4)\n"),
                       "print('DONE1', flush=True)", program(suffix="print('extra')\n"),
                       "print('MEMORY1 0 initial 0 0 0 0', flush=True)",
                       "print('MEMORY1 0 initial 0 0 1938 256', end='', flush=True)"):
            with self.subTest(source=source), self.assertRaises(RuntimeError):
                self.child(source)

    def test_timeout_kills_and_reaps_child(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / "pid"
            source = f"import os,time; open({str(pidfile)!r}, 'w').write(str(os.getpid())); time.sleep(10)"
            with self.assertRaisesRegex(RuntimeError, "timeout"):
                self.child(source, timeout=1)
            pid = int(pidfile.read_text())
            with self.assertRaises(ChildProcessError):
                os.waitpid(pid, os.WNOHANG)
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_output_limit_and_atomic_failure(self):
        with mock.patch.object(measure, "MAX_OUTPUT", 4096), self.assertRaisesRegex(RuntimeError, "limit"):
            self.child("import sys; sys.stderr.write('x'*8192); sys.stderr.flush()")
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / "record.json"
            record.write_text('{"previous":true}\n')
            with self.assertRaises(ValueError):
                measure.write_record(record, {"bad": float("nan")})
            self.assertEqual(json.loads(record.read_text()), {"previous": True})
            self.assertEqual(len(list(Path(directory).iterdir())), 1)


class MemoryProvenanceTests(unittest.TestCase):
    def test_immutable_sources_clean_environment_private_workspace_space_path(self):
        with tempfile.TemporaryDirectory(prefix="memory provenance ") as directory:
            root = Path(directory) / "library"
            root.mkdir()
            (root / "bench").mkdir()
            for name in ("measure.py", "measure_memory.py", "memory.goose"):
                (root / "bench" / name).write_bytes((ROOT / "bench" / name).read_bytes())
            env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
            env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                       MEMORY_TEST_CREDENTIAL="must-not-propagate")
            def git(*args):
                return subprocess.run(["git", *args], cwd=root, env=env, check=True,
                                      capture_output=True, text=True).stdout.strip()
            git("init", "-q")
            git("config", "user.name", "fixture")
            git("config", "user.email", "fixture@example.invalid")
            git("config", "core.hooksPath", str(root / "no-hooks"))
            git("config", "commit.gpgsign", "false")
            (root / "GOOSE_REVISION").write_text("a" * 40 + "\n")
            source_data = {}
            for name in measure.SOURCES:
                source_data[name] = ("// committed " + name + "\n").encode()
                (root / name).write_bytes(source_data[name])
            git("add", ".")
            git("commit", "-qm", "fixed source fixture")
            revision = git("rev-parse", "HEAD")
            for name in measure.SOURCES:
                (root / name).write_text("// dirty working content\n")
            compiler = Path(directory) / "fake goose compiler"
            expected_hashes = {key: measure.sha(data) for key, data in source_data.items()}
            child_program = ("import sys\n"
                             f"exec({program('control')!r} if sys.argv[1] == '3' else {program()!r})\n")
            compiler.write_text(f"#!{sys.executable}\n" + """import hashlib,os,pathlib,sys
assert 'MEMORY_TEST_CREDENTIAL' not in os.environ
assert pathlib.Path(os.environ['GOOSE_HOME']).is_dir()
if sys.argv[1] == '--version':
 print('goose aaaaaaa fixture')
 raise SystemExit()
source = pathlib.Path(sys.argv[2])
""" + f"expected = {expected_hashes!r}\n" + """for name, digest in expected.items():
 assert hashlib.sha256((source.parents[1]/name).read_bytes()).hexdigest() == digest
output = pathlib.Path(sys.argv[sys.argv.index('-o')+1])
""" + f"output.write_text('#!{sys.executable}\\n' + {child_program!r})\noutput.chmod(0o755)\nprint(f'built {{output}}')\n")
            compiler.chmod(0o755)
            output = root / "result.json"
            command = [sys.executable, str(root / "bench/measure_memory.py"), "--goose", str(compiler),
                       "--ref", revision, "--mode", "scalar", "--cycles", "1", "--repeats", "1",
                       "--output", str(output)]
            result = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            record = json.loads(output.read_text())
            self.assertEqual(record["revision"], revision)
            self.assertNotIn(str(directory), json.dumps(record))
            self.assertEqual(set(record["platform"]), {"sysname", "release", "version", "machine"})
            self.assertEqual(record["build_command"][0], "<compiler>")
            self.assertEqual(record["build_stdout"], "built <workspace>/snapshot/memory\n")
            self.assertTrue(record["diagnostics_paths_normalized"])
            self.assertEqual(len(record["build_diagnostics_raw_sha256"]["stdout"]), 64)
            self.assertEqual(record["source_sha256"], expected_hashes)
            self.assertEqual(record["compiler_sha256"], measure.sha(compiler.read_bytes()))
            self.assertEqual(record["harness_sha256"], measure.sha((ROOT / "bench/memory.goose").read_bytes()))
            self.assertEqual(len(record["launcher_controls"]), 1)
            self.assertEqual(list((root / ".build/memory").iterdir()), [])
            # A failed child must not replace a complete existing publication.
            compiler.write_text(compiler.read_text().replace(repr(child_program), repr("raise SystemExit(7)\n")))
            previous = output.read_bytes()
            failed = subprocess.run(command, cwd=root, env=env, capture_output=True, timeout=15)
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(output.read_bytes(), previous)
            self.assertEqual(list((root / ".build/memory").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
