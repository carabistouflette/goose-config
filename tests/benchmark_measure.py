#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Validate benchmark records without building or timing a Goose program."""
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("benchmark_measure", ROOT / "bench/measure.py")
MEASURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MEASURE)


def fixture(index, samples="[7, 0, 3.5, 1.0, 4, 2, 6]"):
    name = MEASURE.FIXTURE_NAMES[index] if index < len(MEASURE.FIXTURE_NAMES) else f"extra-{index}"
    return f"{name} samples_ns={samples} checksum={index - 8}"


def output(first_samples="[7, 0, 3.5, 1.0, 4, 2, 6]", count=16):
    return "\n".join(fixture(index, first_samples) if index == 0 else fixture(index)
                     for index in range(count))


class BenchmarkMeasurementTests(unittest.TestCase):
    def test_valid_numbers_preserve_raw_samples_medians_and_checksums(self):
        records = MEASURE.parse_fixtures(output())
        self.assertEqual(set(records), set(MEASURE.FIXTURE_NAMES))
        for index, name in enumerate(MEASURE.FIXTURE_NAMES):
            self.assertEqual(records[name], {
                "samples_ns": [7, 0, 3.5, 1.0, 4, 2, 6],
                "median_ns": 3.5,
                "checksum": index - 8,
            })

    def test_zero_samples_are_valid(self):
        record = MEASURE.parse_fixtures(output("[0, 0.0, 0, 0.0, 0, 0.0, 0]"))["lookup-small"]
        self.assertEqual(record["median_ns"], 0)
        self.assertEqual(record["samples_ns"], [0, 0.0, 0, 0.0, 0, 0.0, 0])

    def test_summary_lines_do_not_replace_raw_samples(self):
        text = "\n".join(fixture(index) + "\nmedian=99 min=0 max=100" for index in range(16))
        self.assertEqual(MEASURE.parse_fixtures(text), MEASURE.parse_fixtures(output()))

    def test_nonfinite_numbers_are_rejected(self):
        for token in ("NaN", "Infinity", "+Infinity", "-Infinity", "1e999", "-1e999"):
            with self.subTest(token=token), self.assertRaises(ValueError):
                MEASURE.parse_fixtures(output(f"[0, 1, 2, {token}, 4, 5, 6]"))

    def test_nonnumeric_samples_are_rejected(self):
        for token in ("true", "false", '"3"', "[]", "[3]", "{}", "null"):
            with self.subTest(token=token), self.assertRaises(ValueError):
                MEASURE.parse_fixtures(output(f"[0, 1, 2, {token}, 4, 5, 6]"))

    def test_integer_too_large_for_finite_float_is_rejected(self):
        huge_integer = "1" + "0" * 400
        with self.assertRaises(ValueError):
            MEASURE.parse_fixtures(output(f"[0, 1, 2, {huge_integer}, 4, 5, 6]"))

    def test_negative_samples_are_rejected(self):
        for token in ("-1", "-0.5"):
            with self.subTest(token=token), self.assertRaises(ValueError):
                MEASURE.parse_fixtures(output(f"[0, 1, 2, {token}, 4, 5, 6]"))

    def test_wrong_sample_counts_are_rejected(self):
        for samples in ("[]", "[0, 1, 2, 3, 4, 5]", "[0, 1, 2, 3, 4, 5, 6, 7]"):
            with self.subTest(samples=samples), self.assertRaises(ValueError):
                MEASURE.parse_fixtures(output(samples))

    def test_malformed_json_is_rejected(self):
        for samples in ("[0, 1, 2,, 3, 4, 5, 6]", "[0, 1, 2, 3, 4, 5, 6,]",
                        "[0, 1, 2, invalid, 4, 5, 6]"):
            with self.subTest(samples=samples), self.assertRaises(ValueError):
                MEASURE.parse_fixtures(output(samples))

    def test_duplicate_fixture_names_are_rejected(self):
        with self.assertRaises(ValueError):
            MEASURE.parse_fixtures(output() + "\n" + fixture(0, "[1, 1, 1, 1, 1, 1, 1]"))

    def test_exactly_sixteen_fixtures_are_required(self):
        for text in ("", output(count=15), output(count=17)):
            with self.subTest(count=len(text.splitlines())), self.assertRaises(ValueError):
                MEASURE.parse_fixtures(text)

    def test_unknown_names_cannot_replace_expected_fixtures(self):
        for names in (("lookup-small",), MEASURE.FIXTURE_NAMES):
            text = output()
            for index, name in enumerate(names):
                text = text.replace(name + " samples_ns=", f"renamed-{index} samples_ns=")
            with self.subTest(renamed=len(names)), self.assertRaisesRegex(ValueError, "fixture mismatch"):
                MEASURE.parse_fixtures(text)

    def test_explicit_comparison_subset_rejects_extra_and_missing_rows(self):
        names = MEASURE.FIXTURE_NAMES[:2]
        text = "\n".join(fixture(index) for index in range(2))
        self.assertEqual(set(MEASURE.parse_fixtures(text, names)), set(names))
        for invalid in (fixture(0), text + "\n" + fixture(2)):
            with self.assertRaises(ValueError):
                MEASURE.parse_fixtures(invalid, names)


if __name__ == "__main__":
    unittest.main()
