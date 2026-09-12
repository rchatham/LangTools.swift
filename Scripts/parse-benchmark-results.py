#!/usr/bin/env python3
"""Parse verbose XCTest benchmark output into normalized JSON.

Usage:
  Scripts/parse-benchmark-results.py /path/to/swift-test.log
  Scripts/run-extended-tests.sh --filter BenchmarkTests -v 2>&1 | Scripts/parse-benchmark-results.py -
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

MEASURE_RE = re.compile(
    r"Test Case '-\[BenchmarkTests\.(?P<suite>\w+) (?P<test>[^\]]+)\]' "
    r"measured \[Time, seconds\] average: (?P<printed_average>[0-9.]+).*?"
    r"values: \[(?P<values>[^\]]+)\]",
    re.DOTALL,
)

SUITE_PROVIDER = {
    "AnthropicBenchmarkTests": "Anthropic",
    "OpenAIBenchmarkTests": "OpenAI",
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


def parse_results(log: str) -> dict[str, Any]:
    results: dict[str, dict[str, dict[str, Any]]] = {}
    ratios: dict[str, dict[str, float]] = {}

    for match in MEASURE_RE.finditer(log):
        provider = SUITE_PROVIDER.get(match.group("suite"), match.group("suite"))
        subject, operation = parse_test_name(match.group("test"))
        values = [float(value.strip()) for value in match.group("values").split(",")]
        average = statistics.fmean(values)
        median = statistics.median(values)
        stddev = statistics.pstdev(values) if len(values) > 1 else 0.0

        provider_results = results.setdefault(provider, {})
        operation_results = provider_results.setdefault(operation, {})
        operation_results[subject] = {
            "averageSeconds": average,
            "medianSeconds": median,
            "stddevSeconds": stddev,
            "xctestPrintedAverageSeconds": float(match.group("printed_average")),
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
                    provider_ratios[f"{operation}.LangToolsOver{subject}"] = langtools / average
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

    parsed = parse_results(read_input(args.log))
    indent = None if args.compact else 2
    print(json.dumps(parsed, indent=indent, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
