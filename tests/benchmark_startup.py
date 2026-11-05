#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check consumer measurement provenance, behavior and failure cleanup."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bench"))
import consumer_startup as startup


class StartupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="startup tests ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def execute(self, source, **kwargs):
        return startup.execute([sys.executable, "-c", source], cwd=self.root,
                               env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")}, **kwargs)

    def test_output_and_exit_are_preserved(self):
        code, out, error, elapsed = self.execute("import sys; print('out'); print('err',file=sys.stderr); sys.exit(7)")
        self.assertEqual((code, out, error), (7, b"out\n", b"err\n"))
        self.assertGreater(elapsed, 0)

    def captured_processes(self):
        children = []
        real = subprocess.Popen

        def create(*args, **kwargs):
            child = real(*args, **kwargs)
            children.append(child)
            return child

        return children, patch.object(startup.subprocess, "Popen", side_effect=create)

    def test_output_limit_reaps_and_closes_child(self):
        children, capture = self.captured_processes()
        with capture, self.assertRaisesRegex(ValueError, "output budget"):
            self.execute("import os,time; os.write(1,b'x'*100000); time.sleep(60)", budget=4096)
        self.assertIsNotNone(children[0].returncode)
        self.assertTrue(children[0].stdout.closed and children[0].stderr.closed)

    def test_closed_pipes_live_child_has_deadline(self):
        children, capture = self.captured_processes()
        with capture, self.assertRaises((TimeoutError, subprocess.TimeoutExpired)):
            self.execute("import os,time; os.close(1); os.close(2); time.sleep(60)", timeout=1)
        self.assertIsNotNone(children[0].returncode)
        self.assertTrue(children[0].stdout.closed and children[0].stderr.closed)

    def repository(self):
        repo = self.root / "consumer"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "source").write_text("frozen")
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "-qm", "fixture"], cwd=repo, check=True)
        return repo

    def test_export_uses_frozen_commit_not_dirty_tree_or_ambient_git_dir(self):
        repo = self.repository()
        (repo / "source").write_text("dirty")
        with patch.dict(os.environ, {"GIT_DIR": str(self.root / "not-a-repository")}):
            revision, hashes = startup.export(repo, "HEAD", self.root / "snapshot")
        self.assertEqual((self.root / "snapshot/source").read_text(), "frozen")
        self.assertEqual(hashes["source"], startup.sha(b"frozen"))
        self.assertEqual(len(revision), 40)
        self.assertEqual((repo / "source").read_text(), "dirty")

    def test_export_rejects_symlink(self):
        repo = self.repository()
        (repo / "escape").symlink_to(self.root / "outside")
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "-qm", "symlink"], cwd=repo, check=True)
        with self.assertRaisesRegex(ValueError, "unsafe"):
            startup.export(repo, "HEAD", self.root / "snapshot")
        self.assertFalse((self.root / "outside").exists())

    def test_export_ignores_git_replacement_objects(self):
        repo = self.repository()
        original = subprocess.check_output(["git", "rev-parse", "HEAD:source"], cwd=repo).decode().strip()
        replacement = subprocess.check_output(["git", "hash-object", "-w", "--stdin"],
                                              cwd=repo, input=b"tainted").decode().strip()
        subprocess.run(["git", "replace", original, replacement], cwd=repo, check=True)
        self.assertEqual(subprocess.check_output(["git", "cat-file", "blob", original], cwd=repo), b"tainted")
        startup.export(repo, "HEAD", self.root / "snapshot")
        self.assertEqual((self.root / "snapshot/source").read_bytes(), b"frozen")

    def test_export_caps_tree_and_blob_sizes(self):
        repo = self.repository()
        with patch.object(startup, "MAX_EXPORT_FILES", 0), self.assertRaisesRegex(ValueError, "file count"):
            startup.export(repo, "HEAD", self.root / "too-many")
        with patch.object(startup, "MAX_BLOB_BYTES", 3), self.assertRaisesRegex(ValueError, "output budget"):
            startup.export(repo, "HEAD", self.root / "too-large")

    def test_mismatched_vendor_inventory_is_rejected(self):
        (self.root / "vendor").mkdir()
        (self.root / "vendor/lib").mkdir()
        (self.root / "vendor/lib/source").write_text("changed")
        (self.root / "vendor/pins.json").write_text(json.dumps({"lib": {"sha256": {"source": startup.sha(b"original")}}}))
        with self.assertRaisesRegex(ValueError, "inventory mismatch"):
            startup.profile(self.root)

    def test_all_configured_cases_have_matching_effective_limits(self):
        commands, fixtures = startup.fixture_commands(self.root, {"before": Path("/before"), "after": Path("/after")})
        expected = {"expect_exit": 0, "timeout_ms": 30000, "output_limit": 65536}
        for name, metadata in fixtures.items():
            data = (self.root / name).read_bytes()
            decoded = json.loads(data) if name.endswith("json") else tomllib.loads(data.decode())
            self.assertEqual(decoded, expected)
            self.assertEqual(len(data), metadata["bytes"])
            self.assertEqual(startup.sha(data), metadata["sha256"])
            if name.startswith("64k"):
                self.assertEqual(len(data), 65536)
        self.assertEqual(commands["json-cli"][-4:], ["--output-limit", "65536", "--", "/bin/true"])
        self.assertEqual(commands["current-A-no-file"], commands["current-B-no-file"])
        self.assertEqual(commands["current-A-help"], commands["current-B-help"])

    def test_normalization_handles_spaces_quotes_without_changing_samples(self):
        raw = {"command": ['/private/with "quotes"/checker'], "samples_ns": [1, 2, 3]}
        result = startup.normalized(raw, [('/private/with "quotes"', "<ARTIFACTS>")])
        self.assertEqual(result, {"command": ["<ARTIFACTS>/checker"], "samples_ns": [1, 2, 3]})


if __name__ == "__main__":
    unittest.main()
