#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Guard target-specific alias benchmark checksums and sample completeness."""
import sys
from pathlib import Path
import unittest
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'bench'))
from measure_aliases import NAMES, parse_aliases
from diagnostics.alias_lookup import classify, sha, verify_binaries

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
    def test_cached_binary_inventory_and_tampering(self):
        with tempfile.TemporaryDirectory() as tmp:
            workspace=Path(tmp)
            for label in ('before','after'):(workspace/label).write_bytes(label.encode())
            hashes={label:sha((workspace/label).read_bytes()) for label in ('before','after')}
            verify_binaries(workspace,hashes)
            for bad in ({},{'before':hashes['before']},{**hashes,'other':'extra'}):
                with self.assertRaises(ValueError):verify_binaries(workspace,bad)
            (workspace/'after').write_bytes(b'changed')
            with self.assertRaises(ValueError):verify_binaries(workspace,hashes)
    def test_zero_baseline_and_unstable_control_are_inconclusive(self):
        self.assertEqual(classify({'before-A':0,'before-B':0,'after':1},1.15,.10),(None,None,'inconclusive'))
        self.assertEqual(classify({'before-A':1,'before-B':2,'after':3},1.15,.10)[2],'inconclusive')
        self.assertEqual(classify({'before-A':1,'before-B':1,'after':2},1.15,.10)[2],'regression')
        self.assertEqual(classify({'before-A':1,'before-B':1,'after':1},1.15,.10)[2],'within-budget')
if __name__=='__main__':unittest.main()
