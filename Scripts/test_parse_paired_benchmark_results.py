import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("parse-paired-benchmark-results.py")
spec = importlib.util.spec_from_file_location("paired_parser", SCRIPT)
parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parser)
START = "Test Suite 'Selected tests' started at 2026-09-14.\n"
SUCCESS = "Test Suite 'Selected tests' passed at 2026-09-14.\nExecuted 1 test, with 0 failures (0 unexpected) in 1 second\n"


def record(kind="PAIRED_ENCODE", key="OpenAI.1.messageImplementation"):
    result = {"key": key, "iterations": 1000,
              "aSeconds": [0.1] * 10, "bSeconds": [0.2] * 10, "pairedRatios": [2.0] * 10,
              "medianPairedRatio": 2.0, "minPairedRatio": 2.0, "maxPairedRatio": 2.0}
    result.update({"observedBytes": 100, "warmupBatchesPerVariant": 2} if kind == "PAIRED_ENCODE" else {"consumed": 100})
    return result


def line(value=None, kind="PAIRED_ENCODE"):
    return kind + " " + json.dumps(record(kind) if value is None else value) + "\n"


class PairedParserTests(unittest.TestCase):
    def parse(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.log"
            path.write_text(text)
            return parser.parse_log(path)

    def test_collects_both_record_types(self):
        result = self.parse(line(record(key="a")) + line(record("PAIRED_COMPETITOR", "b"), "PAIRED_COMPETITOR") + SUCCESS)
        self.assertEqual(set(result["results"]), {"a", "b"})
        self.assertEqual(result["log"], "run.log")

    def test_collects_buffered_records_after_success_summary(self):
        lifecycle = (START + "Test Suite 'PairedBenchmarks' started at 2026-09-14.\n"
                     "Test Case '-[PairedBenchmarks testEncode]' started.\n"
                     "Test Case '-[PairedBenchmarks testEncode]' passed (1.0 seconds).\n"
                     "Test Suite 'PairedBenchmarks' passed at 2026-09-14.\n"
                     "Executed 1 test, with 0 failures (0 unexpected) in 1 second\n" + SUCCESS)
        trailer = "◇ Test run started.\n✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.\n"
        for kind in ("PAIRED_ENCODE", "PAIRED_COMPETITOR"):
            with self.subTest(kind=kind):
                value = record(kind)
                result = self.parse(lifecycle + line(value, kind) + trailer)
                self.assertEqual(result["results"], {value["key"]: value})

    def test_rejects_multiple_runs_and_stale_success_with_buffered_records(self):
        buffered = START + SUCCESS + line(record(key="first"))
        cases = [
            buffered + START + SUCCESS + line(record(key="second")),
            START + START + SUCCESS + line(),
            buffered + START + line(record(key="second")),
            SUCCESS + START + line(),
            buffered + "Test Case '-[OtherTests testOther]' started.\n",
            buffered + "Test Suite 'OtherTests' passed.\n",
        ]
        for text in cases:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.parse(text)

    def test_rejects_explicit_later_failures_after_buffered_records(self):
        for failure in ("Test Suite 'Selected tests' failed.\n", "error: terminated\n",
                        "fatal error: terminated\n", "Executed 2 tests, with 1 failure\n",
                        "Test run with 1 test failed after 0.001 seconds.\n"):
            with self.subTest(failure=failure), self.assertRaises(ValueError):
                self.parse(START + SUCCESS + line() + failure)

    def test_nonconstant_ratios_and_float_roundoff(self):
        value = record()
        value["bSeconds"] = [0.1 * n for n in range(1, 11)]
        value["pairedRatios"] = list(range(1, 11))
        value.update(medianPairedRatio=5.5, minPairedRatio=1, maxPairedRatio=10)
        result = self.parse(line(value) + SUCCESS.replace("Selected tests", "All tests") + "◇ Test run started.\n✔ Test run with 0 tests passed after 0.001 seconds.\n")
        self.assertEqual(result["results"][value["key"]], value)

    def test_rejects_duplicate_results_across_record_types(self):
        for duplicate in (line(), line(record("PAIRED_COMPETITOR"), "PAIRED_COMPETITOR")):
            with self.subTest(duplicate=duplicate), self.assertRaisesRegex(ValueError, "duplicate"):
                self.parse(line() + duplicate + SUCCESS)

    def test_rejects_failed_empty_missing_or_incomplete_final_runs(self):
        valid = line() + SUCCESS
        cases = ["", line() + START, SUCCESS, line() + SUCCESS.replace("passed", "failed"),
                 valid + "Test Suite 'Selected tests' failed\n", valid + "Test Suite 'Selected tests' started\n",
                 valid + "Test Case '-[OtherTests testOther]' started\n", valid + "error: terminated\n",
                 valid + "Executed 2 tests, with 1 failure\n", valid + SUCCESS,
                 line() + SUCCESS.replace("1 test,", "0 tests,"), "Test Case 'testOther' failed\n" + valid]
        for text in cases:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.parse(text)

    def test_requires_every_producer_field(self):
        for kind in ("PAIRED_ENCODE", "PAIRED_COMPETITOR"):
            for field in record(kind):
                value = record(kind)
                del value[field]
                with self.subTest(kind=kind, field=field), self.assertRaises(ValueError):
                    self.parse(line(value, kind) + SUCCESS)

    def test_rejects_nonobject_or_invalid_keys(self):
        for value in ([], 1, True, "string", {"key": "only"}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.parse(line(value) + SUCCESS)
        for key in ([], {}, None, 1, True, "", "  "):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.parse(line(record(key=key)) + SUCCESS)
        with self.assertRaises(ValueError):
            self.parse("PAIRED_ENCODE null\n" + SUCCESS)

    def test_rejects_invalid_numbers_in_all_sample_and_summary_fields(self):
        for field in ("aSeconds", "bSeconds", "pairedRatios", "medianPairedRatio", "minPairedRatio", "maxPairedRatio"):
            for invalid in (0, -1, float("nan"), float("inf"), -float("inf"), None, True, "0.1", [], {}):
                value = record()
                if isinstance(value[field], list):
                    value[field][0] = invalid
                else:
                    value[field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    self.parse(line(value) + SUCCESS)

    def test_rejects_inconsistent_sample_counts_and_array_types(self):
        for field in ("aSeconds", "bSeconds", "pairedRatios"):
            for invalid in ([], [0.1], [0.1] * 9, [0.1] * 11, None, "samples", {}):
                value = record()
                value[field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    self.parse(line(value) + SUCCESS)
        for count in (0, 9, 11, 10.0, True, "10"):
            value = record()
            value["sampleCount"] = count
            with self.subTest(count=count), self.assertRaises(ValueError):
                self.parse(line(value) + SUCCESS)

    def test_rejects_invalid_integer_metadata(self):
        for kind, fields in (("PAIRED_ENCODE", ("iterations", "observedBytes", "warmupBatchesPerVariant")),
                             ("PAIRED_COMPETITOR", ("iterations", "consumed"))):
            for field in fields:
                for invalid in (0, -1, 2.0, True, "2", None, [], float("inf")):
                    value = record(kind)
                    value[field] = invalid
                    with self.subTest(kind=kind, field=field, invalid=invalid), self.assertRaises(ValueError):
                        self.parse(line(value, kind) + SUCCESS)
        value = record()
        value["warmupBatchesPerVariant"] = 3
        with self.assertRaises(ValueError):
            self.parse(line(value) + SUCCESS)

    def test_rejects_inconsistent_derived_ratios(self):
        for field in ("pairedRatios", "medianPairedRatio", "minPairedRatio", "maxPairedRatio"):
            value = record()
            if field == "pairedRatios":
                value[field][0] = 2.1
            else:
                value[field] = 2.1
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.parse(line(value) + SUCCESS)
        value = record()
        value["aSeconds"][0] = 1e-308
        value["bSeconds"][0] = 1e308
        with self.assertRaises(ValueError):
            self.parse(line(value) + SUCCESS)

    def test_rejects_malformed_json_prefix_and_duplicate_json_fields(self):
        for text in ("PAIRED_ENCODE {\n", "PAIRED_ENCODE\n", "PAIRED_ENCODE_BAD {}\n",
                     line().replace('"iterations": 1000', '"iterations": 1, "iterations": 1000')):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.parse(text + SUCCESS)

    def test_cli_multiple_successful_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ("run.log", "repeat.log")]
            for path, text in zip(paths, (line() + SUCCESS, START + SUCCESS + line())):
                path.write_text(text)
            run = self.cli(paths)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stderr, "")
            result = json.loads(run.stdout)
            self.assertEqual(result["units"], "seconds per batch")
            self.assertEqual([item["log"] for item in result["runs"]], [path.name for path in paths])

    def test_cli_invalid_inputs_have_stderr_and_no_partial_output(self):
        invalid_records = [[], {"key": "only"}, record(key=[])]
        for field, invalid in (("aSeconds", [float("nan")] * 10), ("iterations", True),
                               ("bSeconds", [0.2] * 9), ("medianPairedRatio", 3)):
            value = copy.deepcopy(record())
            value[field] = invalid
            invalid_records.append(value)
        cases = ["", line() + START, line() * 2 + SUCCESS, line() + SUCCESS + "Test Suite 'All tests' failed\n",
                 "PAIRED_ENCODE {\n" + SUCCESS, *[line(value) + SUCCESS for value in invalid_records]]
        with tempfile.TemporaryDirectory() as directory:
            good = Path(directory) / "good.log"
            bad = Path(directory) / "bad.log"
            good.write_text(line() + SUCCESS)
            for text in cases:
                bad.write_text(text)
                with self.subTest(text=text):
                    self.assert_cli_error([good, bad])
            self.assert_cli_error([good, Path(directory) / "missing"])
            self.assert_cli_error([Path(directory)])
            bad.write_bytes(b"\xff")
            self.assert_cli_error([bad])

    def test_records_file_mode_without_xctest_output(self):
        # Dedicated LANGTOOLS_PAIRED_RESULTS_FILE capture: no XCTest summary;
        # the run-success check is delegated to the pipefail capture protocol.
        result = self.parse(line(record(key="a")) + line(record("PAIRED_COMPETITOR", "b"), "PAIRED_COMPETITOR"))
        self.assertEqual(set(result["results"]), {"a", "b"})

    def test_records_file_mode_rejects_empty_or_duplicate(self):
        with self.assertRaises(ValueError):
            self.parse("")
        with self.assertRaises(ValueError):
            self.parse(line() + line())

    def cli(self, paths):
        return subprocess.run([sys.executable, str(SCRIPT), *map(str, paths)], capture_output=True, text=True)

    def assert_cli_error(self, paths):
        run = self.cli(paths)
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(run.stdout, "")
        self.assertIn("error:", run.stderr)
        self.assertNotIn("Traceback", run.stderr)


if __name__ == "__main__":
    unittest.main()
