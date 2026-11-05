#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent typed-workload checksum/parity and protocol regressions."""
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'bench'))
from measure_typed import NAMES,parse

class TypedProtocolTests(unittest.TestCase):
    def output(self,count):
        # Constants independently derived from the controlled JSON documents.
        values={'load-small':(1250000123,1750000124),'load-owned':(1250004139,1750004105),
                'cold-owned':(1250004139,1750004105),'optional-removal':(1250000123,17),
                'refresh-owned':(1250004139,1750004105),'reject-validator':(15,15),
                'reject-schema':(45,45),'application-read':(1,250000000)}
        total=7*count
        return '\n'.join(f'{name} samples_ns=[1,2,3,4,5,6,7] checksum={((total+1)//2)*values[name][0]+(total//2)*values[name][1]}' for name in NAMES)
    def test_fixed_oracle_odd_even_and_bounds(self):
        for count in (1,2,3,1000,100000):self.assertEqual(len(parse(self.output(count),count)),8)
    def test_wrong_checksum_for_every_case(self):
        for line in self.output(3).splitlines():
            changed=line.rsplit('=',1)[0]+'=0'
            with self.assertRaises(ValueError):parse(self.output(3).replace(line,changed),3)
    def test_missing_duplicate_nonfinite_or_incomplete_samples(self):
        valid=self.output(2)
        for output in ('\n'.join(valid.splitlines()[:-1]),valid+'\n'+valid.splitlines()[0],valid.replace('[1,2,3,4,5,6,7]','[1,2,3,4,5,6,NaN]'),valid.replace('[1,2,3,4,5,6,7]','[1,2]')):
            with self.assertRaises(ValueError):parse(output,2)
if __name__=='__main__':unittest.main()
