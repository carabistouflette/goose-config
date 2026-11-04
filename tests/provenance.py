#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise source provenance with isolated Git repositories and fake toolchains."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
COMPILER_PIN = "a" * 40


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="goose-provenance-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root = self.directory / "library"
        self.root.mkdir()
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.environment = dict({key: value for key, value in os.environ.items()
                                 if not key.startswith("GIT_")},
                                PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                                GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                                GIT_TERMINAL_PROMPT="0")

    def run_command(self, command, cwd=None, environment=None):
        return subprocess.run(command, cwd=cwd or self.root,
                              env=environment or self.environment, check=True,
                              capture_output=True, text=True, timeout=20).stdout.strip()

    def init_repository(self, directory):
        directory.mkdir(parents=True, exist_ok=True)
        self.run_command(["git", "init", "-q", str(directory)])
        for key, value in (("user.email", "fixture@example.invalid"),
                           ("user.name", "Provenance fixture"),
                           ("commit.gpgsign", "false"), ("tag.gpgsign", "false"),
                           ("core.hooksPath", str(self.directory / "no-hooks")),
                           ("core.autocrlf", "false")):
            self.run_command(["git", "config", key, value], cwd=directory)

    def commit(self, directory):
        self.run_command(["git", "add", "."], cwd=directory)
        self.run_command(["git", "commit", "-qm", "fixture"], cwd=directory)
        return self.run_command(["git", "rev-parse", "HEAD"], cwd=directory)

    def executable(self, name, source):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o755)
        return path

    def copy_script(self, relative):
        destination = self.root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, destination)
        return destination

    def measurement_module(self):
        spec = importlib.util.spec_from_file_location("provenance_measure", ROOT / "bench/measure.py")
        measure = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(measure)
        return measure

    def stop_process(self, process):
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=3)
        process.communicate()

    def wait_for_file(self, path, process):
        deadline = time.monotonic() + 8
        while not path.exists():
            if process.poll() is not None:
                stdout, stderr = process.communicate()
                self.fail(f"benchmark exited before barrier: {stdout}\n{stderr}")
            if time.monotonic() >= deadline:
                self.fail("benchmark did not reach the build barrier")
            time.sleep(0.01)

    def test_concurrent_benchmarks_keep_their_own_sources_and_binaries(self):
        self.init_repository(self.root)
        script = self.copy_script("bench/measure.py")
        (self.root / ".gitignore").write_text(".build/\n")
        (self.root / "bench/bench.goose").write_text("// fixture harness\n")
        (self.root / "GOOSE_REVISION").write_text(COMPILER_PIN + "\n")
        for name in ("toml.goose", "vendor.goose"):
            (self.root / name).write_text("// fixture\n")
        (self.root / "config.goose").write_text("111\n")
        first_revision = self.commit(self.root)
        (self.root / "config.goose").write_text("222\n")
        second_revision = self.commit(self.root)
        compiler = self.executable("goose", '''from pathlib import Path
import os, sys, time
if sys.argv[1] == "--version":
    print("goose aaaaaaa fixture")
    raise SystemExit()
source = Path(sys.argv[2])
value = int((source.parents[1] / "config.goose").read_text())
output = Path(sys.argv[sys.argv.index("-o") + 1])
program = "#!" + sys.executable + "\\n"
for index, name in enumerate(__FIXTURE_NAMES__):
    row = f"{name} samples_ns={[value] * 7} checksum={index}"
    program += "print(" + repr(row) + ")\\n"
output.write_text(program)
output.chmod(0o755)
if os.environ.get("PROVENANCE_FIRST") and output.parent.name == "after":
    barrier = Path(os.environ["PROVENANCE_BARRIER"])
    (barrier / "ready").touch()
    deadline = time.monotonic() + 12
    while not (barrier / "resume").exists():
        if time.monotonic() >= deadline:
            raise SystemExit("benchmark fixture barrier timed out")
        time.sleep(0.01)
'''.replace("__FIXTURE_NAMES__", repr(self.measurement_module().FIXTURE_NAMES)))
        self.executable("gcc", 'print("gcc fixture")\n')
        command = [sys.executable, str(script), "--goose", str(compiler),
                   "--iterations", "1", "--pairs", "1"]
        first_record = self.directory / "first.json"
        second_record = self.directory / "second.json"
        first_environment = dict(self.environment, PROVENANCE_FIRST="1",
                                 PROVENANCE_BARRIER=str(self.directory))
        first = subprocess.Popen(command + ["--before-ref", first_revision,
                                 "--after-ref", first_revision, "--output", str(first_record)],
                                 cwd=self.root, env=first_environment, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.addCleanup(self.stop_process, first)
        self.wait_for_file(self.directory / "ready", first)
        try:
            self.run_command(command + ["--before-ref", second_revision,
                             "--after-ref", second_revision, "--output", str(second_record)])
        finally:
            (self.directory / "resume").touch()
        stdout, stderr = first.communicate(timeout=15)
        self.assertEqual(first.returncode, 0, f"{stdout}\n{stderr}")
        for path, revision, value in ((first_record, first_revision, 111),
                                      (second_record, second_revision, 222)):
            record = json.loads(path.read_text())
            self.assertEqual(record["revisions"], {"before": revision, "after": revision})
            self.assertEqual(len(record["measurements"]), 2)
            for measurement in record["measurements"]:
                self.assertEqual(len(measurement["fixtures"]), 16)
                for fixture in measurement["fixtures"].values():
                    self.assertEqual(fixture["samples_ns"], [value] * 7)
        self.assertEqual(list((self.root / ".build/paired").iterdir()), [])

    def test_invalid_benchmark_record_preserves_previous_publication(self):
        measure = self.measurement_module()
        destination = self.directory / "record.json"
        destination.write_text('{"previous": true}\n')
        with self.assertRaises(ValueError):
            measure.write_record(destination, {"samples": [float("nan")]})
        self.assertEqual(json.loads(destination.read_text()), {"previous": True})
        self.assertEqual(list(self.directory.glob("*.tmp")), [])

    def toml_fixture(self):
        script = self.copy_script("scripts/setup-toml-test.sh")
        cache = self.root / ".toolchain/toml-test"
        self.init_repository(cache)
        (cache / "cmd/toml-test").mkdir(parents=True)
        (cache / "cmd/toml-test/main.go").write_text("pinned clean source\n")
        (cache / ".gitignore").write_text("ignored.go\n")
        (cache / "go.mod").write_text("module fixture.invalid/toml-test\n")
        revision = self.commit(cache)
        (self.root / "TOML_TEST_REVISION").write_text(revision + "\n")
        log = self.directory / "go-build.json"
        self.environment["PROVENANCE_GO_LOG"] = str(log)
        self.executable("go", '''from pathlib import Path
import json, os, sys
root = Path.cwd()
record = {"cwd": str(root), "arguments": sys.argv[1:],
          "gowork": os.environ.get("GOWORK"),
          "source": (root / "cmd/toml-test/main.go").read_text(),
          "files": sorted(str(path.relative_to(root)) for path in root.rglob("*") if path.is_file())}
Path(os.environ["PROVENANCE_GO_LOG"]).write_text(json.dumps(record))
output = Path(sys.argv[sys.argv.index("-o") + 1]).resolve()
program = "#!" + sys.executable + "\\nimport json, sys\\n"
program += "result = " + repr({"source": record["source"]}) + "\\n"
program += "result.update(binary=__file__, arguments=sys.argv[1:])\\nprint(json.dumps(result))\\n"
output.write_text(program)
output.chmod(0o755)
''')
        return script, cache, revision, log

    def check_toml_pinned_export(self, advance_head):
        script, cache, revision, log = self.toml_fixture()
        head = revision
        if advance_head:
            # The requested commit exists locally even though HEAD has moved.
            (cache / "cmd/toml-test/main.go").write_text("later committed source\n")
            head = self.commit(cache)
        (cache / "cmd/toml-test/main.go").write_text("owner tracked edits\n")
        (cache / "cmd/toml-test/untracked.go").write_text("owner untracked source\n")
        (cache / "cmd/toml-test/ignored.go").write_text("owner ignored source\n")
        before_status = self.run_command(["git", "status", "--porcelain", "--ignored"], cwd=cache)
        before_files = {str(path.relative_to(cache)): path.read_bytes()
                        for path in cache.rglob("*") if path.is_file() and ".git" not in path.relative_to(cache).parts}
        self.run_command(["bash", str(script)])
        build = json.loads(log.read_text())
        self.assertEqual(build["source"], "pinned clean source\n")
        self.assertNotIn("cmd/toml-test/untracked.go", build["files"])
        self.assertNotIn("cmd/toml-test/ignored.go", build["files"])
        self.assertNotIn(".git/HEAD", build["files"])
        self.assertEqual(build["gowork"], "off")
        self.assertIn("-mod=readonly", build["arguments"])
        self.assertIn("-buildvcs=false", build["arguments"])
        self.assertIn(f"-X zgo.at/zli.version={revision}", build["arguments"])
        self.assertFalse(Path(build["cwd"]).exists(), "export must be cleaned after building")
        self.assertEqual(self.run_command(["git", "rev-parse", "HEAD"], cwd=cache), head)
        self.assertEqual(self.run_command(["git", "status", "--porcelain", "--ignored"], cwd=cache), before_status)
        after_files = {str(path.relative_to(cache)): path.read_bytes()
                       for path in cache.rglob("*") if path.is_file() and ".git" not in path.relative_to(cache).parts}
        self.assertEqual(after_files, before_files)
        binary = self.root / ".build/toml-test"
        self.assertEqual(json.loads(self.run_command([str(binary)]))["source"], "pinned clean source\n")

    def test_toml_matching_head_exports_pin_and_preserves_owner_edits(self):
        self.check_toml_pinned_export(advance_head=False)

    def test_toml_different_head_exports_cached_pin_without_checkout_or_fetch(self):
        self.check_toml_pinned_export(advance_head=True)

    def test_toml_run_mode_uses_private_binary_and_forwards_arguments(self):
        script, cache, revision, log = self.toml_fixture()
        build_directory = self.root / ".build"
        build_directory.mkdir()
        public_binary = build_directory / "toml-test"
        public_binary.write_text("previous published binary\n")
        arguments = ["test", "-decoder=/some path/decoder", "-toml=1.0", ""]
        result = json.loads(self.run_command(["bash", str(script), *arguments]))
        self.assertEqual(result["arguments"], arguments)
        self.assertEqual(result["source"], "pinned clean source\n")
        self.assertNotEqual(Path(result["binary"]), public_binary)
        self.assertFalse(Path(result["binary"]).exists(), "private binary must be cleaned after running")
        self.assertEqual(public_binary.read_text(), "previous published binary\n")


if __name__ == "__main__":
    unittest.main()
