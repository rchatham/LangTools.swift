import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("parse-benchmark-results.py")
spec = importlib.util.spec_from_file_location("benchmark_parser", SCRIPT)
parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parser)
SUCCESS = "Test Suite 'Selected tests' passed at 2026-09-14.\nExecuted 1 test, with 0 failures (0 unexpected) in 1 second\n"


def measure(subject="LangTools", operation="DecodeResponse", values="0.1, 0.2, 0.3", average="0.200", suite="OpenAIBenchmarkTests"):
    return (f"Test Case '-[BenchmarkTests.{suite} test{subject}_{operation}]' "
            f"measured [Time, seconds] average: {average}, relative standard deviation: 10.0%, "
            f"values: [{values}], performanceMetricID:org.swift.XCTPerformanceMetric_WallClockTime\n")


class BenchmarkParserTests(unittest.TestCase):
    def test_normalizes_statistics_and_ratio(self):
        result = parser.parse_results(measure() + measure("Baseline", values="0.1, 0.1, 0.1") + SUCCESS)
        metrics = result["results"]["OpenAI"]["decodeResponse"]["LangTools"]
        self.assertAlmostEqual(metrics["averageSeconds"], 0.2)
        self.assertEqual(metrics["medianSeconds"], 0.2)
        self.assertAlmostEqual(metrics["stddevSeconds"], 0.0816496580927726)
        self.assertEqual(metrics["sampleCount"], 3)
        self.assertAlmostEqual(result["ratios"]["OpenAI"]["decodeResponse.LangToolsOverFoundation.JSONSerialization"], 2)

    def test_historical_subjects_and_current_operations(self):
        for subject in ("OpenAISwift", "MacPaw", "SwiftOpenAI", "SwiftAnthropic"):
            with self.subTest(subject=subject):
                result = parser.parse_results(measure(subject, "EncodeRequest_LargeConversation") + SUCCESS)
                self.assertIn(subject, result["results"]["OpenAI"]["encodeLargeConversation"])

    def test_rounded_zero_average_scientific_samples_and_all_tests(self):
        result = parser.parse_results(measure(values="1e-7", average="0.000", suite="AnthropicBenchmarkTests") + SUCCESS.replace("Selected tests", "All tests") + "◇ Test run started.\n✔ Test run with 0 tests passed after 0.001 seconds.\n")
        metrics = result["results"]["Anthropic"]["decodeResponse"]["LangTools"]
        self.assertEqual(metrics["stddevSeconds"], 0)
        self.assertEqual(metrics["xctestPrintedAverageSeconds"], 0)

    def test_rejects_empty_missing_failed_and_incomplete_final_runs(self):
        valid = measure() + SUCCESS
        cases = ["", SUCCESS, measure(), measure() + SUCCESS.replace("passed", "failed"),
                 valid + "Test Suite 'Selected tests' failed\n",
                 valid + "Test Suite 'Selected tests' started\n",
                 valid + "Test Case '-[OtherTests testOther]' started\n",
                 valid + "error: build failed\n", valid + "error: terminated\n",
                 valid + "Executed 2 tests, with 1 failure\n", valid + SUCCESS,
                 SUCCESS + measure(), measure() + SUCCESS.replace("1 test,", "0 tests,"),
                 "Test Case 'testOther' failed\n" + valid]
        for text in cases:
            with self.subTest(text=text), self.assertRaises(ValueError):
                parser.parse_results(text)

    def test_rejects_duplicate_identity_and_normalized_collision(self):
        for duplicate in (measure(), measure(suite="OpenAIAdditionalCompetitorBenchmarkTests")):
            with self.subTest(duplicate=duplicate), self.assertRaisesRegex(ValueError, "duplicate"):
                parser.parse_results(measure() + duplicate + SUCCESS)

    def test_rejects_invalid_samples(self):
        for values in ("", "0", "-0.1", "nan", "inf", "-inf", "1e999", "hello", "0.1,", "0.1, 0", "0.1, NaN"):
            with self.subTest(values=values), self.assertRaises(ValueError):
                parser.parse_results(measure(values=values) + SUCCESS)

    def test_rejects_invalid_printed_average(self):
        for average in ("nan", "inf", "-1", "text"):
            with self.subTest(average=average), self.assertRaises(ValueError):
                parser.parse_results(measure(average=average) + SUCCESS)

    def test_does_not_skip_malformed_measurement_or_cross_lines(self):
        for bad in (measure().replace("values: [0.1, 0.2, 0.3]", "values: ["),
                    measure().replace("average: 0.200", "average:"),
                    measure().replace("values:", "samples:")):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                parser.parse_results(bad + measure("Baseline") + SUCCESS)

    def test_rejects_nonfinite_derived_ratio(self):
        with self.assertRaises(ValueError):
            parser.parse_results(measure(values="1e308") + measure("Baseline", values="1e-308") + SUCCESS)

    def test_cli_stdin_and_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.log"
            path.write_text(measure() + SUCCESS)
            for args, text in (([str(path)], None), (["-", "--compact"], path.read_text())):
                with self.subTest(args=args):
                    run = subprocess.run([sys.executable, str(SCRIPT), *args], input=text, capture_output=True, text=True)
                    self.assertEqual(run.returncode, 0, run.stderr)
                    self.assertEqual(run.stderr, "")
                    self.assertIn("results", json.loads(run.stdout))

    def test_cli_invalid_and_unreadable_inputs(self):
        for text in ("", measure(), measure(values="nan") + SUCCESS, measure() * 2 + SUCCESS,
                     measure() + SUCCESS + "Test Suite 'All tests' failed\n"):
            with self.subTest(text=text):
                self.assert_cli_error(["-"], text)
        with tempfile.TemporaryDirectory() as directory:
            self.assert_cli_error([str(Path(directory) / "missing")])
            self.assert_cli_error([directory])
            path = Path(directory) / "invalid-utf8.log"
            path.write_bytes(b"\xff")
            self.assert_cli_error([str(path)])

    def assert_cli_error(self, args, text=None):
        run = subprocess.run([sys.executable, str(SCRIPT), *args], input=text, capture_output=True, text=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(run.stdout, "")
        self.assertIn("error:", run.stderr)
        self.assertNotIn("Traceback", run.stderr)


if __name__ == "__main__":
    unittest.main()
