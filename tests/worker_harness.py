#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check acceptance-harness writes without compiling the optional worker."""
import os
import sys
import unittest

from worker import Worker


class HarnessTests(unittest.TestCase):
    def test_blocked_stdin_has_deadline_and_child_is_reaped(self):
        child = Worker([sys.executable, "-c", "import time; time.sleep(60)"],
                       os.environ.copy(), timeout=1)
        try:
            with self.assertRaisesRegex(RuntimeError, "stdin write timeout"):
                child.send("x" * 1048576, "unused")
        finally:
            child.close()
        self.assertIsNotNone(child.process.returncode)

    def test_large_write_is_complete_and_protocol_survives(self):
        source = ('import sys\nprint("ready",flush=True)\n'
                  'for line in sys.stdin.buffer:\n'
                  ' if line == b"quit\\n":\n'
                  '  print("bye",flush=True); break\n'
                  ' print(len(line)-1,flush=True)\n')
        child = Worker([sys.executable, "-c", source], os.environ.copy())
        try:
            child.line("ready")
            child.send("x" * 200000, "200000")
            child.finish()
        finally:
            child.close()


if __name__ == "__main__":
    unittest.main()
