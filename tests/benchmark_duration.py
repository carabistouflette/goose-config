#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Reject invalid duration benchmark protocols before publishing results."""
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'bench'))
SPEC = importlib.util.spec_from_file_location('compare_durations', ROOT/'bench/compare_durations.py')
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)

class DurationBenchmarkTests(unittest.TestCase):
    def output(self, count, checksum=None):
        expected = 7*(((count+1)//2)*250000000+(count//2)*1500000000)
        return '\n'.join(f'{name} samples_ns=[1,2,3,4,5,6,7] checksum={expected if checksum is None else checksum}' for name in BENCH.FIXTURES)

    def test_odd_even_and_single_operation_batches(self):
        for count in (1, 2, 3, 100000):
            with self.subTest(count=count):
                self.assertEqual(set(BENCH.parse_durations(self.output(count), count)), set(BENCH.FIXTURES))

    def test_incorrect_checksums(self):
        with self.assertRaises(ValueError): BENCH.parse_durations(self.output(2, checksum=0), 2)

    def test_missing_duplicate_and_unknown_cases(self):
        valid = self.output(2)
        for invalid in ('\n'.join(valid.splitlines()[:-1]), valid.replace('duration-json', 'duration-get'), valid.replace('duration-json', 'unknown')):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                BENCH.parse_durations(invalid, 2)

    def test_nonfinite_and_incomplete_timings(self):
        valid = self.output(2)
        for samples in ('[1,2,3,4,5,6]', '[1,2,3,4,5,6,NaN]', '[1,2,3,4,5,6,-1]', '[1,2,3,4,5,6,true]'):
            with self.subTest(samples=samples), self.assertRaises(ValueError):
                BENCH.parse_durations(valid.replace('[1,2,3,4,5,6,7]', samples), 2)

    def test_extra_output(self):
        with self.assertRaises(ValueError): BENCH.parse_durations(self.output(2)+'\nignored', 2)

if __name__ == '__main__': unittest.main()
