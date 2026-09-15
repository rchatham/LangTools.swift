#!/usr/bin/env python3
"""Collect paired benchmark JSON records from successful XCTest logs.

Usage: Scripts/parse-paired-benchmark-results.py run.log repeat.log > results.json
Timing units are seconds per batch; ratio is B/A (see each experiment's key).
"""
import argparse
import json
import math
import re
import statistics
from pathlib import Path


def validate_run(log: str) -> None:
    """Require one completed XCTest invocation, not a stale success in a bad log."""
    # Scan failure keywords only over XCTest/output lines, not over record
    # payloads, so a benchmark `key` containing "failed"/"error:" cannot
    # falsely reject a valid legacy log.
    non_record = "\n".join(
        line for line in log.splitlines()
        if not line.startswith(("PAIRED_ENCODE", "PAIRED_COMPETITOR"))
    )
    if re.search(r"\b(?:failed|failure)\b|\b(?:fatal error|error:)", non_record, re.IGNORECASE):
        raise ValueError("log contains a failure or error")
    if re.search(r"Executed \d+ tests?, with [1-9]\d* failures?", log):
        raise ValueError("log contains test failures")
    events = list(re.finditer(r"Test (?:Suite|Case) ['\"].+?['\"] (started|passed|failed|skipped)\b", log))
    summaries = list(re.finditer(r"Test Suite '(?:Selected tests|All tests)' passed\b", log))
    if len(summaries) != 1:
        raise ValueError("expected one final successful Selected tests or All tests summary")
    starts = re.findall(r"Test Suite '(?:Selected tests|All tests)' started\b", log)
    if len(starts) > 1:
        raise ValueError("expected one XCTest invocation")
    final = summaries[0]
    # stdout records may flush after XCTest's stderr summary. Require the
    # summary to be the last lifecycle event, not the last output in the log.
    if not events or events[-1].start() != final.start():
        raise ValueError("missing final successful test run summary")
    counts = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", log)
    if counts and int(counts[-1][0]) == 0:
        raise ValueError("final run executed no tests")


def is_records_file(log: str) -> bool:
    """A dedicated records file (LANGTOOLS_PAIRED_RESULTS_FILE) has no XCTest output."""
    return not re.search(r"Test (?:Suite|Case) ['\"].+?['\"] (started|passed|failed|skipped)\b|Executed \d+ tests?", log)


def validate_run_records_file(path: Path, records: dict) -> None:
    """Dedicated records files rely on the pipefail capture protocol; reject empty output."""
    if not records:
        raise ValueError(f"{path}: no paired benchmark records")


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def positive_number(value: object, field: str) -> float:
    if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
        raise ValueError(f"{field} must be a finite positive number")
    return value


def positive_integer(record: dict, field: str) -> None:
    if type(record.get(field)) is not int or record[field] <= 0:
        raise ValueError(f"{field} must be a positive integer")


def validate_record(record: object, kind: str) -> None:
    if not isinstance(record, dict):
        raise ValueError("paired record must be an object")
    if not isinstance(record.get("key"), str) or not record["key"].strip():
        raise ValueError("key must be a nonempty string")
    positive_integer(record, "iterations")
    positive_integer(record, "observedBytes" if kind == "PAIRED_ENCODE" else "consumed")
    if kind == "PAIRED_ENCODE":
        if type(record.get("warmupBatchesPerVariant")) is not int or record["warmupBatchesPerVariant"] != 2:
            raise ValueError("warmupBatchesPerVariant must be 2")
    # Both current Swift producers and historical artifacts contain ten pairs.
    for field in ("aSeconds", "bSeconds", "pairedRatios"):
        values = record.get(field)
        if not isinstance(values, list) or len(values) != 10:
            raise ValueError(f"{field} must contain ten samples")
        for value in values:
            positive_number(value, field)
    if "sampleCount" in record and (type(record["sampleCount"]) is not int or record["sampleCount"] != 10):
        raise ValueError("sampleCount must match the ten pairs")
    ratios = [b / a for a, b in zip(record["aSeconds"], record["bSeconds"])]
    for actual, expected in zip(record["pairedRatios"], ratios):
        positive_number(expected, "derived ratio")
        if not math.isclose(actual, expected, rel_tol=1e-9, abs_tol=0):
            raise ValueError("pairedRatios must equal bSeconds / aSeconds")
    for field, expected in (("medianPairedRatio", statistics.median(ratios)),
                            ("minPairedRatio", min(ratios)), ("maxPairedRatio", max(ratios))):
        actual = positive_number(record.get(field), field)
        if not math.isclose(actual, expected, rel_tol=1e-9, abs_tol=0):
            raise ValueError(f"{field} does not match derived ratios")


def parse_log(path: Path) -> dict:
    text = path.read_text()
    records = {}
    for line in text.splitlines():
        if not line.startswith(("PAIRED_ENCODE", "PAIRED_COMPETITOR")):
            continue
        parts = line.split(" ", 1)
        if len(parts) != 2 or parts[0] not in ("PAIRED_ENCODE", "PAIRED_COMPETITOR"):
            raise ValueError(f"{path}: malformed paired record prefix")
        kind, payload = parts
        record = json.loads(payload, object_pairs_hook=unique_object)
        validate_record(record, kind)
        key = record["key"]
        if key in records:
            raise ValueError(f"{path}: duplicate result {key}")
        records[key] = record
    if not records:
        raise ValueError(f"{path}: no paired benchmark records")
    if is_records_file(text):
        # Dedicated records file (LANGTOOLS_PAIRED_RESULTS_FILE): no XCTest
        # output is present, so the run-success check is delegated to the
        # pipefail capture protocol in docs/benchmark-capture.md.
        validate_run_records_file(path, records)
    else:
        validate_run(text)
    return {"log": path.name, "results": records}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path, nargs="+")
    args = parser.parse_args()
    try:
        runs = [parse_log(path) for path in args.logs]
        output = json.dumps({"units": "seconds per batch", "runs": runs}, indent=2, sort_keys=True, allow_nan=False)
    except (ValueError, OSError, OverflowError) as error:
        parser.error(str(error))
    print(output)


if __name__ == "__main__":
    main()
