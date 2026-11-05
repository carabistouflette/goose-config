#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent generated-binding checksum and failure-protocol regressions."""
from pathlib import Path
import sys
import contextlib
import io
import os
import tempfile
from unittest.mock import patch
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bench'))
from measure_generated_bindings import NAMES, parse, run, RunFailure, failure_record, main


class GeneratedBindingProtocolTests(unittest.TestCase):
    def output(self, count):
        # Six old-worker descriptor byte totals in the dynamic index order.
        cycle = (33, 42, 48, 48, 38, 39)
        construct = 7 * (sum(cycle) * (count // 6) + sum(cycle[:count % 6]))
        return '\n'.join(
            f'{name} samples_ns=[1,2,3,4,5,6,7] checksum={construct if name == "construct" else 63 * count}'
            for name in NAMES)

    def test_oracle_covers_partial_and_complete_cycles(self):
        for count in (1, 2, 3, 6, 7, 1000, 100000):
            self.assertEqual(len(parse(self.output(count), count)), 3)

    def test_wrong_checksum_for_every_case(self):
        for line in self.output(3).splitlines():
            with self.assertRaises(ValueError):
                parse(self.output(3).replace(line, line.rsplit('=', 1)[0] + '=0'), 3)

    def test_missing_duplicate_nonfinite_or_incomplete_samples(self):
        valid = self.output(2)
        for output in ('\n'.join(valid.splitlines()[:-1]), valid + '\n' + valid.splitlines()[0],
                       valid.replace('[1,2,3,4,5,6,7]', '[1,2,3,4,5,6,NaN]'),
                       valid.replace('[1,2,3,4,5,6,7]', '[1,2]')):
            with self.assertRaises(ValueError):
                parse(output, 2)

    def test_failed_process_keeps_both_streams_and_status(self):
        command=[sys.executable,'-c','import sys;print("partial");print("diagnostic",file=sys.stderr);sys.exit(3)']
        with self.assertRaises(RunFailure) as caught:run(command)
        row=failure_record({'phase':'measurement','caller':'generated'},caught.exception,[])
        self.assertEqual(row['raw_stdout'],'partial\n');self.assertEqual(row['raw_stderr'],'diagnostic\n')
        self.assertEqual(row['returncode'],3);self.assertFalse(row['timed_out']);self.assertEqual(row['argv'],command)

    def test_timeout_keeps_partial_output(self):
        command=[sys.executable,'-c','import time;print("ready",flush=True);time.sleep(10)']
        with self.assertRaises(RunFailure) as caught:run(command,timeout=1)
        row=failure_record({'phase':'measurement'},caught.exception,[])
        self.assertTrue(row['timed_out']);self.assertEqual(row['raw_stdout'],'ready\n')

    def test_protocol_failure_keeps_output_and_redacts_snapshot_paths(self):
        pending={'phase':'measurement','argv':['/repo/snapshot/native','3','generated'],'raw_stdout':'corrupt','raw_stderr':''}
        row=failure_record(pending,ValueError('bad protocol'),[('/repo','<repository>'),('/repo/snapshot','<snapshot>')])
        self.assertEqual(row['argv'][0],'<snapshot>/native');self.assertEqual(row['raw_stdout'],'corrupt')
        self.assertEqual(row['exception_type'],'ValueError')

    def test_output_artifact_overwrite_and_collision_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);assembly=root/'native.asm';output=root/'results.json';assembly.write_text('retained')
            cpu=min(os.sched_getaffinity(0))
            for path in (assembly,output):
                argv=['measure_generated_bindings.py','--goose','/does/not/exist','--cpu',str(cpu),'--output',str(output),'--disassembly-output',str(path)]
                with patch.object(sys,'argv',argv),contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as caught:main()
                self.assertEqual(caught.exception.code,2)
            self.assertEqual(assembly.read_text(),'retained');self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
