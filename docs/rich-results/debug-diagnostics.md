# Rich Result Debug Diagnostics

DEBUG-only, privacy-safe diagnostics for diagnosing why a structured tool/agent
result did not render as a rich content card (e.g. a missing Calendar card).

All of this is compiled out of release builds. The public helper lives in
`LangTools` (`RichResultDiagnostics`) so it is shared by the core `Agents`
runtime, the `Chat` sample service, and the Botsworth app.

## Filtering in Xcode

Every emitted line begins with the fixed prefix:

```text
[RichResult]
```

Filter the Xcode console with `RichResult` (or `[RichResult]`) to see only these
diagnostics. No payload, prompt, schema body, error description, custom model
identifier, or raw coding key is ever printed.

## What gets logged (metadata only)

- **Agent request** (`[agent-request]`): a random per-execution trace ID, the
  allowlisted agent label, the allowlisted known-model label, the allowlisted
  provider label, where the effective
  schema came from (`agent`/`context`/`none`), whether a schema was requested,
  whether the request conforms to structured output, and whether the schema was
  actually present on the request (`applied`). This records what was *requested
  and placed on the request*; it does **not** claim server enforcement.
- **Agent completion** (`[agent-complete]`): trace ID, coarse result shape
  (`empty`/`fenced`/`object`/`array`/`text`), byte count, and error flag.
- **Agent error** (`[agent-error]`): trace ID, allowlisted agent label, and a
  fixed category (`transfer`/`execution`) with no error interpolation.
- **Decode failure** (`[decode]`): allowlisted structured-output type label,
  fixed `DecodingError` category (`keyNotFound`/`typeMismatch`/`valueNotFound`/
  `dataCorrupted`/`other`), coding-path depth and allowlisted field labels, byte
  count, and result shape. Unknown coding keys render as `redacted`.
- **Registry** (`[registry]`): namespace (`agent`/`tool`), allowlisted agent
  label (agent namespace only), and a fixed outcome
  (`registryMiss`/`decodeNil`/`emptyItems`/`parsed`), plus the allowlisted card
  type and item count when a result was parsed.
- **Presentation** (`[presentation]`): namespace, allowlisted agent label, fixed
  outcome (`attached`/`attachMissed`/`standalone`/`legacy`/`raw`), and the
  history/rich setting booleans. `attached` is logged only after the invocation
  card was actually found and updated; `attachMissed` means the rich payload was
  parsed but no matching pending invocation card existed to attach it to.
- **Model selection** (`[model]`): the selected conversation route and its
  known-model label, the agent model override route and label (or `none`), and
  the rich/history setting booleans. The agent's *effective* model (after the
  override is applied downstream) is logged in the `[agent-request]` line.

## Example (metadata only)

```text
[RichResult][agent-request] trace=3F9A2C1D agent=calendar model=claude-sonnet-4-6 provider=anthropic schema=agent requested=yes supportsStructuredOutput=yes applied=yes
[RichResult][decode] type=calendarAgentResponse category=keyNotFound depth=3 path=events.redacted.startDate bytes=142 shape=object
[RichResult][registry] namespace=agent agent=calendar outcome=decodeNil
[RichResult][presentation] namespace=agent agent=calendar outcome=raw history=yes rich=yes
```

This sequence diagnoses the common "calendar card missing" failure: the agent
requested a schema and it was applied, but decoding failed because the event at
array index `0` was missing `startDate`. The numeric array index is not a known
calendar field name, so it renders as `redacted` in the coding path
(`events.redacted.startDate`); the registry produced no content and the
completion fell back to the raw text presentation.

## Privacy model

- **Closed allowlists only.** Agent names, card types, provider/route names,
  exact built-in model identifiers, structured-output type names, and calendar
  field names are mapped through finite, hard-coded allowlists. Anything
  unrecognized maps to a fixed `other`/`redacted`/`custom` label and is never
  echoed.
- **No charset whitelisting.** ASCII-looking secrets (API keys, tokens, custom
  model IDs) still map to `other`/`redacted`; the classifiers never pass a
  runtime string through to output.
- **Never printed:** raw JSON, prompts, response content, schema bodies, schema
  titles, error descriptions/underlying errors, arbitrary coding keys, custom
  model identifiers, event data, and custom IDs.
- **Emission is `#if DEBUG`.** All classification and emission happens at
  DEBUG-gated call sites; release builds contain none of this code and perform
  no parse-for-logging work.

## Limitations

- **Strict-schema field coverage.** The `[decode]` path only surface-tests the
  coding path against the known Calendar/structured-card field allowlist. A
  failure on a field outside that list renders as `path=...redacted...`, so the
  category and depth remain visible even when the exact key is hidden.
- **Known-set redaction.** Only the built-in agents, card types, providers, and
  structured-output types are named; custom agents/card types/providers appear
  as `other`. Add new known entries to `RichResultDiagnostics` as built-in
  integrations are introduced.
- **No server-enforcement claim.** `applied=yes` means the schema was present on
  the outgoing request; it does not verify the provider honored it. When the
  request type cannot be inspected safely, this is reported as `no`/unavailable
  rather than inferred from the request.
- **Unknown provider transports render `provider=other`.** The agent-request
  provider label is derived from the concrete SDK provider type name. An
  account-backed/Backend transport (e.g. Codex/Claude-Code via the proxy) is not
  a known SDK provider type, so its label is honestly `other`, not a guessed
  provider. Agent execution through those transports is separately rejected by
  `agentContext`, so this is an edge case, not a silent mislabel.
- **Tool names are not logged.** Tool results carry a generic `namespace=tool`
  and omit the tool name entirely, because tool names can be arbitrary/custom.
  This is an intentional limitation; add a closed tool allowlist if per-tool
  correlation is ever required.
- **Curated model allowlist.** Known model identifiers are mapped through a
  finite, closed set of family labels. The allowlist covers the exact SDK enum
  forms — canonical, dated (e.g. `gpt-4o-2024-08-06`), and `-latest` aliases
  (e.g. `claude-sonnet-4-5-latest`) — all collapsing to their family label
  (e.g. `gpt-4o`, `claude-sonnet-4-5`). A `route/slug` composite (e.g.
  `anthropic/claude-sonnet-4-6`) has its known route prefix stripped exactly
  once; an unknown prefix or any custom slug renders as `model=custom`. Ollama
  models are always `custom` (they have no fixed built-in catalog). The raw
  slug is never printed.
