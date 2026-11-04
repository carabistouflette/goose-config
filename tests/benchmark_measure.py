#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Validate benchmark records without building or timing a Goose program."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


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


def updates_output(samples="[7, 0, 3.5, 1.0, 4, 2, 6]"):
    return "\n".join(f"{name} samples_ns={samples} checksum={index}"
                     for index, name in enumerate(MEASURE.UPDATE_FIXTURE_NAMES))


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

    def test_updates_suite_requires_its_exact_five_rows(self):
        names = MEASURE.UPDATE_FIXTURE_NAMES
        text = updates_output()
        self.assertEqual(tuple(MEASURE.parse_fixtures(text, names)), names)
        for invalid in (output(), "\n".join(text.splitlines()[:-1]),
                        text + "\n" + fixture(0), text + "\n" + text.splitlines()[0],
                        text.replace(names[0], "renamed-update")):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                MEASURE.parse_fixtures(invalid, names)
        with self.assertRaises(ValueError):
            MEASURE.parse_fixtures(text)

    def test_updates_suite_uses_strict_seven_sample_validation(self):
        for samples in ("[0, 1, 2, true, 4, 5, 6]", "[0, 1, 2, NaN, 4, 5, 6]",
                        "[0, 1, 2, -1, 4, 5, 6]", "[0, 1, 2, 3, 4, 5]",
                        "[0, 1, 2,, 3, 4, 5, 6]"):
            with self.subTest(samples=samples), self.assertRaises(ValueError):
                MEASURE.parse_fixtures(updates_output(samples), MEASURE.UPDATE_FIXTURE_NAMES)

    def test_suite_option_defaults_to_original_core_harness(self):
        required = ["--goose", "/compiler", "--before-ref", "before", "--output", "/record"]
        parser = MEASURE.argument_parser()
        args = parser.parse_args(required)
        self.assertEqual(args.suite, "core")
        self.assertEqual(MEASURE.SUITES[args.suite], ("bench/bench.goose", MEASURE.FIXTURE_NAMES))
        args = parser.parse_args(required + ["--suite", "updates"])
        self.assertEqual(MEASURE.SUITES[args.suite], ("bench/updates.goose", MEASURE.UPDATE_FIXTURE_NAMES))

    def test_updates_harness_is_copied_exactly_into_both_private_exports(self):
        with tempfile.TemporaryDirectory(prefix="benchmark-suite-") as temporary:
            root = Path(temporary)
            (root / "bench").mkdir()
            harness = b"// selected updates harness\r\n"
            (root / "bench/updates.goose").write_bytes(harness)
            (root / "bench/bench.goose").write_bytes(b"// unselected core harness\n")
            destination = root / "result.json"
            builds = []
            executions = []

            def fake_run(command, **kwargs):
                if command[1:] == ["--version"]:
                    return "goose aaaaaaa fixture\n"
                if command[:2] == ["git", "rev-parse"]:
                    return "b" * 40 + "\n"
                if command[:2] == ["git", "show"]:
                    return "a" * 40 + "\n" if command[2].endswith(":GOOSE_REVISION") else "// exported library source\n"
                if len(command) > 1 and command[1] == "build":
                    source = Path(command[2])
                    self.assertEqual(source.name, "bench.goose")
                    self.assertEqual(source.read_bytes(), harness)
                    self.assertEqual(set(path.name for path in source.parents[1].iterdir()),
                                     {"config.goose", "toml.goose", "vendor.goose", "bench"})
                    builds.append(source)
                    return ""
                if command == ["gcc", "--version"]:
                    return "gcc fixture\n"
                executions.append(Path(command[0]).parent.name)
                return updates_output()

            arguments = ["measure.py", "--goose", str(root / "compiler"), "--before-ref", "before",
                         "--suite", "updates", "--iterations", "1", "--pairs", "2", "--output", str(destination)]
            with mock.patch.object(MEASURE, "ROOT", root), mock.patch.object(MEASURE, "run", side_effect=fake_run), \
                    mock.patch("sys.argv", arguments), contextlib.redirect_stdout(io.StringIO()):
                MEASURE.main()
            record = json.loads(destination.read_text())
            self.assertEqual(record["suite"], "updates")
            self.assertEqual(record["harness_path"], "bench/updates.goose")
            self.assertEqual(record["harness_sha256"], MEASURE.hashlib.sha256(harness).hexdigest())
            self.assertEqual(executions, ["before", "after", "after", "before"])
            self.assertEqual(len(builds), 2)
            self.assertTrue(all(not source.exists() for source in builds))
            self.assertEqual(list((root / ".build/paired").iterdir()), [])
            for measurement in record["measurements"]:
                self.assertEqual(tuple(measurement["fixtures"]), MEASURE.UPDATE_FIXTURE_NAMES)


if __name__ == "__main__":
    unittest.main()
