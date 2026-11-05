#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Guard target-specific alias benchmark checksums and sample completeness."""
import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'bench'))
from measure_aliases import NAMES, parse_aliases

class AliasProtocolTests(unittest.TestCase):
    def output(self,count):
        return '\n'.join(f'{name} samples_ns=[1,2,3,4,5,6,7] checksum={7*sum((i*73)%int(name.split("-")[1])+1 for i in range(count))}' for name in NAMES)
    def test_preflight_parity_and_sizes(self):
        for count in (1,2,3,100):self.assertEqual(len(parse_aliases(self.output(count),count)),12)
    def test_wrong_target_checksum(self):
        text=self.output(3).replace('checksum=42','checksum=43',1)
        with self.assertRaises(ValueError):parse_aliases(text,3)
    def test_equal_value_mapping_blind_spot_rejected(self):
        text='\n'.join(f'{name} samples_ns=[1,2,3,4,5,6,7] checksum={7*3*42}' for name in NAMES)
        with self.assertRaises(ValueError):parse_aliases(text,3)
    def test_incomplete_duplicate_or_nonfinite_rows(self):
        valid=self.output(2)
        for text in ('\n'.join(valid.splitlines()[:-1]),valid.replace('alias-8 ', 'canonical-8 '),valid.replace('[1,2,3,4,5,6,7]','[1,2,3,4,5,6,NaN]')):
            with self.assertRaises(ValueError):parse_aliases(text,2)
if __name__=='__main__':unittest.main()
