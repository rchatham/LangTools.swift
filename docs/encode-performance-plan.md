# Encode performance improvement plan

## Active scope

OpenAISwift was removed at the maintainer's request from active benchmarks, optional dependencies, and the HTML comparison. Current alternatives: SwiftOpenAI, MacPaw/OpenAI, SwiftAnthropic. No remaining measured encode disadvantage against these clients on the normalized fixtures; MacPaw decode is approximately tied. Prior OpenAISwift references below are historical, not remaining work. Raw experimental records are retained unchanged.

Removal validation: default benchmark suite 17 passed / 7 skipped; remaining-competitor release suite 33 passed / 7 skipped; opt-in paired suite 4 passed with 12 comparison records. Dependency comments and both generated lockfiles restored. Current HTML ratios, column counts, timing rows, and desktop/mobile layout checked.

## Latest: request encoder fix — 2026-09-14

Implemented explicit optional-presence guards in `OpenAI.ChatCompletionRequest.encode(to:)` after prototype measurement. Simple encoding uses ~17–18% less time; LangTools is the lowest observed encode time against SwiftOpenAI, MacPaw/OpenAI, and SwiftAnthropic on normalized fixtures in both runs. Decode approximately ties MacPaw (within ~2% of parity, marked no clear winner). All optional fields and JSON strategies have regression coverage. Independent reviewer PASS; security-reviewer has no remaining actionable findings after the parser/dedicated-file-capture fix. Paired results re-captured with a dedicated results file to avoid stdout interleaving; parser now validates both records-file and legacy log modes (29 Python tests). See [request-encoder-review.md](request-encoder-review.md) and [request-encoder-results.json](request-encoder-results.json). Changes remain uncommitted pending atomic commit approval.

## Earlier controlled follow-up — 2026-09-13

Completed controlled release message-path A/B, request-envelope component experiments, normalized competitor encode parity, and paired decode repeats. See [paired-performance-review.md](paired-performance-review.md) and [paired-performance-results.json](paired-performance-results.json) for the current assessment. The historical observations below are retained but superseded for gap prioritization.

- The suspected simple-message regression was not reproduced; current/legacy ratios were ~0.83–0.85 for one-message fixtures.
- Normalized simple encode beats SwiftOpenAI/MacPaw/SwiftAnthropic in both runs. Remaining gap: LangTools takes ~24–25% more time than OpenAISwift on simple encode.
- Corrected a benchmark defect: SwiftAnthropic requires `.convertToSnakeCase` to emit `max_tokens`; the earlier encode test emitted `maxTokens`. All normalized encode comparisons now assert identical wire JSON and match stream defaults.
- Component experiments identify request-envelope overhead worth investigating, not proof that a custom encoder will help. No new production optimization was made in this follow-up.
- Final provider/benchmark/ratio tests: 129 passed, 6 intentionally skipped; parser tests: 3 passed. Competitors remain opt-in; dependency files restored. Independent reviewer found no must-fix issues in the paired harness/report; publication pending.

## Review

- Compare all four optional clients: SwiftOpenAI, MacPaw/OpenAI, OpenAISwift, SwiftAnthropic.
- Benchmark equivalence is per operation, not per library. OpenAISwift drops tool-call fields and uses a smaller response model; its timings are limited-shape observations, not evidence of equivalent work.
- Current snapshots are local debug runs, not production throughput guarantees. Repeat same-machine measurements and retain raw logs; noise can reverse small differences.
- Custom request encoders are hypotheses: synthesized encoding already omits nil optionals, and `KeyedEncodingContainer.encode(CodableIgnored:forKey:)` in `Sources/LangTools/LangTools.swift` is already a no-op. There is no nested closure serialization to eliminate. Defer wholesale request encoder duplication until profiling isolates a benefit.

## Execution

1. Run baseline benchmarks and provider tests.
2. Encode message role/string content directly in keyed containers; preserve null, arrays, metadata, and tool-result behavior. Add JSON-equivalence regression tests before accepting the optimization.
3. Compare before/after locally; retain only justified changes.
4. Add non-gating Foundation encode ratios for simple/large requests for both providers; retain existing gates unchanged.
5. Temporarily enable all competitors, run full matrix, record versions and limitations, restore optional dependency comments/pins.
6. Refresh benchmark JSON/HTML and document target outcomes honestly. Targets: OpenAI large within 8% of SwiftOpenAI and ahead of MacPaw; Anthropic large within 5% of SwiftAnthropic; preserve simple-encode competitiveness. These are goals, not reasons to weaken models or tests.
7. Run provider tests, benchmark and ratio suites; request independent review. No commits/push until review and atomic commit approval.

## Follow-up experiments

If message fast paths leave meaningful gaps, profile optimized builds before trying custom request encoders. Measure optional-wrapper overhead independently and preserve all wire fields (including existing null behavior) rather than silently dropping fields. Investigate comparable text-response decode only after encode work; never remove tool parsing to match OpenAISwift.

## Progress

- Baseline debug benchmark run: `/tmp/encode-before.log` (16 tests passed).
- Scout and independent reviewer delegation blocked by subscription session limit; inspection performed inline. Independent review remains pending.
- Implemented direct role/string/null/array encoding in both message encoders, preserving OpenAI tool-result flattening and optional metadata. Request encoders and public APIs unchanged.
- Added reference-encoder parity tests for Unicode, empty strings/arrays, null, all OpenAI roles, tools, metadata/audio/refusal, and multimodal blocks. Both provider suites: 106 tests passed.
- Added four non-gating Foundation ratios with warmup, alternating order, seven samples, and observable output byte counts. Existing ceilings unchanged.
- Final competitor-disabled provider/benchmark/ratio run: 129 tests passed (`/tmp/encode-final-tests.log`). All four competitors enabled: 36 tests passed per run in two debug runs, two optimized release runs, and one release baseline run.
- Optional dependencies and `Package.resolved` restored. Unrelated dirty ChatUI submodule untouched.

### Observed results (milliseconds per measure block)

| Operation | Release before | Release after (first / repeat) | Competitors in repeated release run |
| --- | ---: | ---: | --- |
| OpenAI large encode | 10.040 | 7.424 / 7.222 | SwiftOpenAI 9.167; MacPaw/OpenAI 10.295; OpenAISwift 7.898 |
| Anthropic large encode | 8.716 | 5.539 / 4.928 | SwiftAnthropic 7.861 |
| OpenAI simple encode | 3.143 | 3.397 / 3.691 | SwiftOpenAI 3.654; MacPaw/OpenAI 2.770; OpenAISwift 2.123 |
| Anthropic simple encode | 2.971 | 2.918 / 2.830 | SwiftAnthropic 2.195 |

Large-encode goals were observed in both debug and release repetitions. Simple-encode goals are **not met consistently**; OpenAI simple encode is noisy and worse than the baseline in these release runs. The fast path is retained for the repeated large-conversation gains, not claimed as a universal speedup. Separate runs and XCTest ordering introduce substantial variance: these are observations, not statistical confidence intervals. Full samples, run order, environment, and resolved competitor revisions are in `encode-performance-experiment.json`.

Reporting-only Foundation ratios from the final debug run: OpenAI simple 3.168×, large 2.547×; Anthropic simple 2.592×, large 2.045×. These are typed serialization vs an already-built dictionary, not competitor rankings.

### Remaining work

- Controlled profiling of simple-request encode in release builds (longer measurement blocks and alternating implementations in the same process) before adding custom request encoders.
- Validate exact per-operation fixture/default equivalence before interpreting small competitor differences: OpenAISwift explicitly encodes `stream: false` while LangTools defaults to omission; request model/default fields also vary across clients.
- Investigate comparable decode gaps vs MacPaw/OpenAI and SwiftAnthropic after controlling run variance. No decode behavior was changed in this experiment; do not interpret ranking changes as decode regressions without paired measurements.
- Independent review is blocked until the subscription resets. Changes are uncommitted; update PR title/description and attach a visual artifact (or explain why unnecessary for numeric table-only changes) before publishing.
