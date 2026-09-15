# OpenAI request encoder investigation — 2026-09-14

**Active comparison scope:** the active alternatives are SwiftOpenAI, MacPaw/OpenAI, and SwiftAnthropic. OpenAISwift was removed from benchmark code, dependency options, and the HTML tables at the maintainer's request; references to it below record historical motivation and experiments only. The latest competitor results were re-captured with a **dedicated results file** (`LANGTOOLS_PAIRED_RESULTS_FILE`) to avoid stdout interleaving; see [benchmark-capture.md](benchmark-capture.md).

## Decision

Retain an explicit `ChatCompletionRequest.encode(to:)` that checks optional presence before dispatching to the keyed container. Controlled release runs show **~17–18% less time on simple requests**, with no meaningful regression on 50-message or populated-option fixtures. Public stored properties, required fields, key names, and synthesized decoding remain unchanged.

The normalized simple-encode gap vs OpenAISwift narrowed from **24–25% more time to 2–3% more time**. The first post-fix run's paired sample range crosses 1.0; the second does not. Treat the remaining difference as a small residual requiring more evidence, not proof of parity or grounds for another speculative rewrite.

This is not a closure serialization optimization: `CodableIgnored` already used no-op keyed encoding. The candidate instead skips absent-option container calls. Component measurements support the change; no Instruments profiling was performed.

## Experiment sequence

1. Test-only prototype with all request fields and `if let` guards vs the unchanged production encoder, in the existing alternating paired harness.
2. Repeat prototype measurements and verify populated-wire parity.
3. Apply the same encoder to production; preserve original `_choose` and `toolEventHandler` coding keys for synthesized ignored-wrapper decoding, but never encode them.
4. Add default-suite wire regression tests. Compare production against a test-only synthesized reference with the former field layout, including ignored callbacks. Also compare prototype/production to check wrapper-placement effects.
5. Repeat all four normalized competitor comparisons, not just the favorable pair. Restore optional dependencies afterward.

Ratios below are median paired B/A; ten alternating AB/BA pairs after two warmup batches per variant. Simple batches contain 10,000 operations, large batches 1,000 operations (50 messages/request), rich batches 2,000 operations. Sample ranges are not confidence intervals. Raw seconds are **per batch**, not per request.

## Results

| Current encoder / synthesized reference | First run | Repeat |
| --- | ---: | ---: |
| Simple, stream omitted | 0.821 | 0.826 |
| Simple, stream false | 0.834 | 0.826 |
| 50 messages, stream omitted | 0.984 | 0.991 |
| 50 messages, stream false | 0.990 | 0.989 |
| All optional fields populated | 0.972 | 0.981 |

Production/prototype calibration medians were approximately 1.00 (0.994–1.011 across cases). The synthesized reference is a test-only reconstruction, not a second linked historical library; the pre-change prototype runs independently confirm the simple-request gain against the then-actual production encoder (ratios 0.815–0.842).

| LangTools / competitor, after fix (dedicated-file capture, 2026-09-14) | First run | Repeat |
| --- | ---: | ---: |
| OpenAI simple / SwiftOpenAI | 0.786 | 0.787 |
| OpenAI simple / MacPaw/OpenAI | 0.763 | 0.768 |
| OpenAI large / SwiftOpenAI | 0.750 | 0.746 |
| OpenAI large / MacPaw/OpenAI | 0.593 | 0.584 |
| Anthropic simple / SwiftAnthropic | 0.715 | 0.728 |
| Anthropic large / SwiftAnthropic | 0.617 | 0.615 |

Decode medians (LangTools / competitor): OpenAI text vs MacPaw 1.017 / 1.009, vs SwiftOpenAI 0.798 / 0.804; OpenAI tool-call vs MacPaw 0.986 / 0.994, vs SwiftOpenAI 0.842 / 0.849; Anthropic text 0.841 / 0.840, Anthropic tool-use 0.920 / 0.920. The MacPaw decode pairs sit within ~2% of parity, so the HTML marks them as no clear winner rather than a win for either side.

No Anthropic or decode implementation changed in this follow-up. Their timings are monitoring observations, not attributed improvements.

## Correctness and verification

- Default OpenAI suite tests all 26 optional request fields populated together, individually present, and individually absent; checks supplied top-level keys survived decoding.
- Additional cases: omitted/empty collections, false/zero values, alternate stop/tool-choice/response-format forms, Unicode, callback omission, callback preservation on the original request, nil callbacks after decode, round-trip re-encoding.
- Compares against former `encodeIfPresent` behavior with default, snake-case, and custom-prefixed JSON key strategies. Checks nonconforming float throwing and configured string conversion.
- Normalized competitor encode pairs assert complete sorted-key JSON equality before measurement. SwiftAnthropic uses its transport's snake-case strategy; stream defaults match across clients.
- Provider suites: **110 passed**.
- Production/reference release runs: **2 passed each**, twice. Normalized competitor release runs: **4 passed each**, twice.
- Final competitor-disabled provider/benchmark/ratio run: **134 passed, 7 opt-in tests skipped** (141 discovered).
- Initial test setup used an untyped empty array and crashed with signal 11. Explicit `[OpenAI.Message]()` fixed the test setup; root cause was not independently diagnosed. Successful run artifacts exclude the failed attempt. No unrelated initializer change was made.
- Independent review of the request encoder and tests is **complete** (reviewer PASS, security-reviewer no remaining actionable findings after the parser/capture fix). Review of the benchmark parser/dedicated-file capture is also complete.

## Reproduction and artifacts

```bash
set -o pipefail
rm -f paired.jsonl
LANGTOOLS_PAIRED_RESULTS_FILE=$PWD/paired.jsonl \
LANGTOOLS_RUN_PAIRED_BENCHMARKS=1 Scripts/run-extended-tests.sh -c release \
  --filter 'testRequestEncoderCurrentVsLegacy|RequestEncoderPrototypeTests' --no-parallel &&
python3 Scripts/parse-paired-benchmark-results.py paired.jsonl > results.json
# Enable the three remaining optional competitor packages/products for the current suite:
rm -f paired.jsonl
LANGTOOLS_PAIRED_RESULTS_FILE=$PWD/paired.jsonl \
LANGTOOLS_RUN_PAIRED_BENCHMARKS=1 Scripts/run-extended-tests.sh -c release \
  --filter PairedCompetitorBenchmarkTests --no-parallel &&
python3 Scripts/parse-paired-benchmark-results.py paired.jsonl > results.json
# Restore Package.swift / Package.resolved to their original opt-in state afterward.
Scripts/run-extended-tests.sh --filter 'BenchmarkTests|OpenAITests|AnthropicTests|PerformanceRatioGateTests|RequestEncodeRatioTests'
python3 -m unittest Scripts.test_parse_benchmark_results Scripts.test_parse_paired_benchmark_results
```

[request-encoder-results.json](request-encoder-results.json) contains the latest dedicated-file capture (two runs) plus the earlier prototype/reference/competitor runs and exact dependency revisions. Older [paired-performance-results.json](paired-performance-results.json) remains the pre-request-fix record. The HTML comparison uses only the repeated post-fix competitor run, with the first post-fix run also checked for inconclusive winner highlighting.

All existing uncommitted work is preserved. Package.swift/Package.resolved restored, dirty ChatUI submodule untouched. Additional optimization is not justified solely to chase the remaining decode near-parity.
