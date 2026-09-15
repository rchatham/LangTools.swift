# Controlled performance follow-up — 2026-09-13

**Historical pre-request-fix investigation.** A subsequent measured request-encoder change reduced the remaining gap to ~2–3%; see [request-encoder-review.md](request-encoder-review.md) and [request-encoder-results.json](request-encoder-results.json). The results below are preserved, not updated in place.

## Outcome

The earlier simple-encode regression is **not reproduced by the controlled message-path experiment**. Retain the existing message fast paths. No additional production encoder changes were made in this follow-up.

The main remaining comparable encode gap is **OpenAI simple encode vs OpenAISwift (~24–25% more time)**. The earlier Anthropic simple-encode gap disappears when the competitor encodes valid, matching API JSON. Decode is approximately even with MacPaw and faster than SwiftOpenAI/SwiftAnthropic on these fixtures using each SDK's required settings (including SwiftAnthropic's snake-case conversion overhead). OpenAISwift's reduced decode model remains non-equivalent work.

## Method

- Release SwiftPM builds; local arm64 macOS, Swift 6.1.0, macOS 15.6 (24G84).
- Two independent executions of each experiment suite.
- Each comparison: two warmup batches per variant, ten measured pairs, alternating AB/BA order, monotonic uptime clock. No XCTest `measure` rounding or warmup samples in the reported median.
- Simple encode: 10,000 operations/batch; large encode: 1,000 operations/batch of 50 messages; decode: 5,000 operations/batch. Samples are **seconds per batch**, not per request.
- Encode outputs are consumed by byte count. Decode outputs are held through `withExtendedLifetime` and consumed by type size; this is a model decode experiment, not downstream application processing.
- Sorted-key JSON parity is asserted outside timing before any encode pair. Production encoder formatting remains default during measurement.
- Ratios are median **paired B/A** ratios. Sample ranges in the artifact are dispersion observations, **not confidence intervals**. No strict performance gates were added.
- These are targeted component experiments, **not Instruments stack/CPU profiling**. Request-envelope differences identify a candidate, not a proven internal bottleneck.

## Old/new message-path experiment

Test-only request mirrors use the same required fixture fields and identical generic request layout for old/new message encoders. Current-message wrappers forward without adding encoding containers; legacy wrappers reproduce the pre-optimization encoding implementation. Wrapper calibration compares wrapped/current vs unwrapped/current; production-vs-mirror checks measure request-envelope differences separately. Mirrors are not general replacements for full requests and omit the full models' absent-optional handling.

| Component (B/A) | First median | Repeat median |
| --- | ---: | ---: |
| OpenAI one message, current/legacy | 0.835 | 0.845 |
| Anthropic one message, current/legacy | 0.832 | 0.833 |
| OpenAI 50 messages, current/legacy | 0.698 | 0.702 |
| Anthropic 50 messages, current/legacy | 0.658 | 0.657 |
| OpenAI simple full request / fixture-only request | 1.293 | 1.270 |
| Anthropic simple full request / fixture-only request | 1.149 | 1.144 |

Simple wrapper calibration was within ~1% at the median; large wrapper overhead reached ~2.5%. The measured old/new gains materially exceed this. This supports the message optimization but is **not an exact A/B of the full former production request type**.

Full request envelope overhead shrinks to ~1% for 50 messages. OpenAI's richer message shape costs ~18–20% versus a flat role/string model on the large fixture; Anthropic's current message encoding is approximately even with that flat model. The fixture-only request does less optional-field work, so it is an investigative lower bound, not an API-compatible optimization.

## Normalized competitor results

All ratios below are **LangTools / competitor**; below 1 is less time for LangTools.

| Operation | Competitor | First | Repeat |
| --- | --- | ---: | ---: |
| OpenAI simple encode | SwiftOpenAI | 0.940 | 0.950 |
| OpenAI simple encode | MacPaw/OpenAI | 0.921 | 0.930 |
| OpenAI simple encode | OpenAISwift | 1.244 | 1.246 |
| OpenAI large encode | SwiftOpenAI | 0.751 | 0.757 |
| OpenAI large encode | MacPaw/OpenAI | 0.580 | 0.578 |
| OpenAI large encode | OpenAISwift | 0.950 | 0.949 |
| Anthropic simple encode | SwiftAnthropic | 0.741 | 0.707 |
| Anthropic large encode | SwiftAnthropic | 0.616 | 0.611 |
| OpenAI response decode | SwiftOpenAI | 0.813 | 0.808 |
| OpenAI response decode | MacPaw/OpenAI | 1.000 | 1.004 |
| OpenAI tool-call decode | SwiftOpenAI | 0.849 | 0.850 |
| OpenAI tool-call decode | MacPaw/OpenAI | 0.995 | 1.010 |
| Anthropic response decode | SwiftAnthropic | 0.831 | 0.819 |
| Anthropic tool-use decode | SwiftAnthropic | 0.932 | 0.918 |

OpenAISwift reduced-model ratios: response decode **1.155 / 1.151**, tool-call decode **1.623 / 1.616**. It does not retain tool calls. Identical input bytes do not establish identical work or output capabilities.

### Fixture audit and corrections

- OpenAI requests now explicitly encode `stream: false` in all four clients; message strings, roles, count, model and all emitted keys/values match for each timed encode pair.
- Anthropic requests use `max_tokens: 4096`, matching model/messages, and `stream: false`.
- Crucially, the old SwiftAnthropic encode benchmark used default JSONEncoder settings, producing **`maxTokens` rather than `max_tokens`**. Its SDK transport (`Sources/Anthropic/Private/Network/Endpoint.swift`) sets `.convertToSnakeCase`. The normalized benchmark does likewise. The earlier apparent simple-encode advantage was not a valid comparison of matching API wire payloads.
- SwiftAnthropic decode retains `.convertFromSnakeCase`, as its actual service requires. Giving both SDKs identical decoder settings would not necessarily be correct; compare each SDK's valid configuration. Decode model field retention still differs, so these are SDK/fixture observations, not universal equal-work rankings.
- Historical XCTest encode fixtures were also corrected; old snapshots are preserved as historical evidence, not silently relabeled as normalized data.

## Verification and reproduction

```bash
# No competitors needed for component experiment:
LANGTOOLS_RUN_PAIRED_BENCHMARKS=1 Scripts/run-extended-tests.sh -c release --filter PairedEncodeBenchmarkTests
# Temporarily uncomment optional packages/products first for competitor experiment:
LANGTOOLS_RUN_PAIRED_BENCHMARKS=1 Scripts/run-extended-tests.sh -c release --filter PairedCompetitorBenchmarkTests
python3 Scripts/parse-paired-benchmark-results.py component.log component-repeat.log competitors.log competitors-repeat.log > results.json
python3 Scripts/test_parse_paired_benchmark_results.py
```

Raw paired samples: [paired-performance-results.json](paired-performance-results.json). Optional package versions/revisions are included in that artifact. Component runs passed 2 tests each; competitor runs passed 4 tests each. The corrected historical benchmark suite passed 36 tests with 6 opt-in tests skipped. Final competitor-disabled provider/benchmark/ratio run passed 129 tests with 6 opt-in tests skipped (135 discovered). Parser tests: 3 passed. Optional dependency comments and `Package.resolved` were restored; unrelated ChatUI submodule untouched.

## Next decision

1. Prioritize a **test-only custom request-encoder prototype** for OpenAI simple encode; compare with the full production request in the same paired harness. Envelope measurements justify investigating this now, but do not prove a production rewrite is worthwhile.
2. Require exhaustive optional-field and callback-omission parity, custom JSONEncoder strategy checks, and repeatable wins before accepting a custom request encoder. Do not silently narrow public behavior to a benchmark fixture.
3. Keep MacPaw decode parity as a monitoring result, not a reason for speculative decode rewrites. Do not drop tool parsing to match OpenAISwift.
4. Independent reviewer completed the harness/report review with no must-fix findings; limitations above remain. Atomic commit approval remains before publication. No new commits/pushes in this follow-up.
