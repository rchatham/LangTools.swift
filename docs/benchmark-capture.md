# Capturing trustworthy benchmark logs

Use **one XCTest invocation per log**, retaining its final `Selected tests` or
`All tests` summary. Do not concatenate retries: a failed run must not be hidden
by another run's success. Both parsers reject empty measurements, malformed
records, duplicate identities, explicit failures, and missing/failing final
XCTest summaries. The paired parser accepts the historical and current
`PAIRED_ENCODE` and `PAIRED_COMPETITOR` schemas: ten positive finite pairs,
positive iteration/work counters, and B/A ratios consistent with the samples.
Encoder records also declare two warmup batches per variant. Ratio comparisons
allow relative floating-point roundoff of `1e-9`, not rounded report percentages.
Ordinary XCTest printed averages may round to zero; raw samples may not.

## Preferred: dedicated results file (avoids stdout interleaving)

Paired records exceed the pipe's atomic write size, so `print` output can
interleave with XCTest progress on shared stdout. Route records to a dedicated
file instead, then parse that file. The parser detects this records-file mode
(no XCTest output present) and relies on the pipefail protocol below for
run-success validation.

```bash
set -o pipefail
rm -f paired.jsonl
LANGTOOLS_PAIRED_RESULTS_FILE=$PWD/paired.jsonl \
LANGTOOLS_RUN_PAIRED_BENCHMARKS=1 Scripts/run-extended-tests.sh \
  -c release --filter PairedCompetitorBenchmarkTests --no-parallel &&
python3 Scripts/parse-paired-benchmark-results.py paired.jsonl > paired-results.json.tmp &&
mv paired-results.json.tmp paired-results.json
```

The legacy `2>&1 | tee` capture below still works for ad-hoc use, but prefer the
dedicated file for reproducible published evidence.

## Capture first, parse only after producer success

Run in bash or zsh with `pipefail`. Without it, `tee` or a parser can return zero
even when `swift test` failed. A log parser cannot recover the producer's actual
exit status (for example, a process killed after printing its success summary).

```bash
set -o pipefail

# Ordinary XCTest measure output. -v preserves the raw sample values.
Scripts/run-extended-tests.sh -c release --filter BenchmarkTests -v \
  2>&1 | tee benchmark.log &&
python3 Scripts/parse-benchmark-results.py benchmark.log > benchmark-results.json.tmp &&
mv benchmark-results.json.tmp benchmark-results.json

# Paired tests require explicit opt-in and the intended optional dependencies.
# Prefer the dedicated results file above; the legacy log capture remains
# supported for ad-hoc use.
LANGTOOLS_RUN_PAIRED_BENCHMARKS=1 Scripts/run-extended-tests.sh \
  -c release --filter PairedEncodeBenchmarkTests \
  2>&1 | tee paired.log &&
python3 Scripts/parse-paired-benchmark-results.py paired.log > paired-results.json.tmp &&
mv paired-results.json.tmp paired-results.json
```

Repeat paired captures into separate log paths; pass those paths together to the
paired parser. It validates every input before emitting any JSON. The temporary
output plus `&& mv` pattern preserves an existing artifact if capture or parsing
fails. Inspect the shell exit status, not just whether a JSON file exists.

These checks establish structural integrity, not benchmark provenance, wire
parity, representativeness, or statistical significance. Retain raw logs,
source revision, compiler/build configuration, dependency pins, and machine
metadata with published evidence. XCTest text parsing follows the existing
macOS verbose measurement format; unrelated test runners are not supported.
