#!/usr/bin/env python3
"""Parse verbose XCTest benchmark output into normalized JSON.

Usage:
  Scripts/parse-benchmark-results.py /path/to/swift-test.log
  set -o pipefail  # Required when capturing a producer through a pipeline.
  Scripts/run-extended-tests.sh --filter BenchmarkTests -v 2>&1 | Scripts/parse-benchmark-results.py -
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

MEASURE_RE = re.compile(
    r"Test Case '-\[BenchmarkTests\.(?P<suite>\w+) (?P<test>[^\]]+)\]' "
    r"measured \[Time, seconds\] average: (?P<printed_average>[^,\s]+)[^\n]*?"
    r"values: \[(?P<values>[^\]\n]*)\]",

)

SUITE_PROVIDER = {
    "AnthropicBenchmarkTests": "Anthropic",
    "OpenAIBenchmarkTests": "OpenAI",
    "OpenAIAdditionalCompetitorBenchmarkTests": "OpenAI",
}

OPERATION_NAMES = {
    "DecodeResponse": "decodeResponse",
    "DecodeStreamChunk": "decodeStreamChunk",
    "DecodeToolCallResponse": "decodeToolCallResponse",
    "DecodeToolUseResponse": "decodeToolUseResponse",
    "EncodeRequest": "encodeRequest",
    "EncodeRequest_LargeConversation": "encodeLargeConversation",
    "MessageConstruction": "messageConstruction",
    "RoundTrip": "roundTrip",
    "StreamLineDecode": "streamLineDecode",
}

SUBJECT_NAMES = {
    "Baseline": "Foundation.JSONSerialization",
    "LangTools": "LangTools",
    "SwiftAnthropic": "SwiftAnthropic",
    "SwiftOpenAI": "SwiftOpenAI",
}


def read_input(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    return Path(path).read_text()


def parse_test_name(name: str) -> tuple[str, str]:
    raw = name.removeprefix("test")
    subject, _, operation = raw.partition("_")
    if not operation:
        return subject, raw
    return SUBJECT_NAMES.get(subject, subject), OPERATION_NAMES.get(operation, operation)


def validate_run(log: str, last_record_end: int) -> None:
    """Require one completed XCTest invocation, not a stale success in a bad log."""
    if re.search(r"\b(?:failed|failure)\b|\b(?:fatal error|error:)", log, re.IGNORECASE):
        raise ValueError("log contains a failure or error")
    if re.search(r"Executed \d+ tests?, with [1-9]\d* failures?", log):
        raise ValueError("log contains test failures")
    events = list(re.finditer(r"Test (?:Suite|Case) ['\"].+?['\"] (started|passed|failed|skipped)\b", log))
    summaries = list(re.finditer(r"Test Suite '(?:Selected tests|All tests)' passed\b", log))
    if len(summaries) != 1:
        raise ValueError("expected one final successful Selected tests or All tests summary")
    final = summaries[0]
    if final.start() < last_record_end or not events or events[-1].start() != final.start():
        raise ValueError("missing final successful test run summary")
    counts = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", log)
    if counts and int(counts[-1][0]) == 0:
        raise ValueError("final run executed no tests")


def parse_results(log: str) -> dict[str, Any]:
    results: dict[str, dict[str, dict[str, Any]]] = {}
    ratios: dict[str, dict[str, float]] = {}

    matches = list(MEASURE_RE.finditer(log))
    candidates = re.findall(r"^.*Test Case .*BenchmarkTests\..*measured.*$", log, re.MULTILINE)
    if not matches:
        raise ValueError("no benchmark measurements")
    if len(candidates) != len(matches):
        raise ValueError("malformed benchmark measurement")
    validate_run(log, matches[-1].end())
    identities: set[tuple[str, str]] = set()
    for match in matches:
        identity = (match.group("suite"), match.group("test"))
        if identity in identities:
            raise ValueError(f"duplicate measurement: {identity}")
        identities.add(identity)
        provider = SUITE_PROVIDER.get(match.group("suite"), match.group("suite"))
        subject, operation = parse_test_name(match.group("test"))
        values = [float(value.strip()) for value in match.group("values").split(",")]
        if not values or any(not math.isfinite(value) or value <= 0 for value in values):
            raise ValueError(f"samples must be finite and positive: {identity}")
        printed_average = float(match.group("printed_average"))
        # XCTest rounds small averages to 0.000; raw samples remain authoritative.
        if not math.isfinite(printed_average) or printed_average < 0:
            raise ValueError(f"invalid printed average: {identity}")
        average = statistics.fmean(values)
        median = statistics.median(values)
        stddev = statistics.pstdev(values) if len(values) > 1 else 0.0

        provider_results = results.setdefault(provider, {})
        operation_results = provider_results.setdefault(operation, {})
        if subject in operation_results:
            raise ValueError(f"duplicate normalized measurement: {provider}.{operation}.{subject}")
        if not all(math.isfinite(value) for value in (average, median, stddev)):
            raise ValueError(f"nonfinite derived statistics: {identity}")
        operation_results[subject] = {
            "averageSeconds": average,
            "medianSeconds": median,
            "stddevSeconds": stddev,
            "xctestPrintedAverageSeconds": printed_average,
            "sampleCount": len(values),
            "valuesSeconds": values,
        }

    for provider, provider_results in results.items():
        provider_ratios: dict[str, float] = {}
        for operation, operation_results in provider_results.items():
            langtools = operation_results.get("LangTools", {}).get("averageSeconds")
            if not isinstance(langtools, float):
                continue
            for subject, metrics in operation_results.items():
                if subject == "LangTools":
                    continue
                average = metrics.get("averageSeconds")
                if isinstance(average, float) and average > 0:
                    ratio = langtools / average
                    if not math.isfinite(ratio) or ratio <= 0:
                        raise ValueError(f"invalid derived ratio: {provider}.{operation}.{subject}")
                    provider_ratios[f"{operation}.LangToolsOver{subject}"] = ratio
        if provider_ratios:
            ratios[provider] = provider_ratios

    return {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "results": results,
        "ratios": ratios,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", help="Verbose XCTest log path, or '-' for stdin")
    parser.add_argument("--compact", action="store_true", help="Emit compact JSON output")
    args = parser.parse_args()

    try:
        parsed = parse_results(read_input(args.log))
        indent = None if args.compact else 2
        output = json.dumps(parsed, indent=indent, sort_keys=True, allow_nan=False)
    except (ValueError, OSError, OverflowError) as error:
        parser.error(str(error))
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
