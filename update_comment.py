import json
import subprocess

h = chr(35)

body_parts = [
    "<!-- claude-code-review -->",
    h + h + " Code Review: Add OpenAI Responses API support",
    "",
    "This PR adds `OpenAI.ResponseRequest` / `ResponseResponse` / `Item` as a first-class LangTools request type, bridging the Responses API input-item/output-item shape onto the existing streaming, tool-calling, and structured-output protocols. The approach (reusing `OpenAI.Message` value types, custom `Codable` paths to flatten tool calls, event-based streaming via `ResponseStreamEvent`) is sound. Test coverage is good \u2014 request encoding, response decoding, streaming, and the full tool-call loop are all exercised.",
    "",
    "**Update (commit `246576a`):** The four issues from the initial review have been addressed. One minor item remains open below.",
    "",
    "---",
    "",
    h + h + h + " Fixed",
    "",
    "| Issue | Severity | Status |",
    "|-------|----------|--------|",
    "| `message` nil-guard included `output.isEmpty` \u2014 returned spurious blank assistant turn for reasoning-model responses | High | Fixed: `if text.isEmpty && calls.isEmpty` |",
    "| `Item.encode` silently dropped all tool calls after the first | Medium | Fixed: throws `EncodingError.invalidValue` with pointer to `ResponseRequest` |",
    "| `(try? container.decodeIfPresent(...)) ?? nil` \u2014 redundant after `try?` | Low | Fixed: simplified to `try? container.decode(...)` |",
    "| `ToolSelection(index: 0, ...)` \u2014 all synthesised tool calls got the same index | Low | Fixed: `index: calls.count` |",
    "",
    "---",
    "",
    h + h + h + " Acknowledged, deferred",
    "",
    "**`decodeStream` runtime type check** (`Sources/OpenAI/OpenAI.swift`, line 56): `T.self == ResponseResponse.self` is a concrete type test where a protocol hook would be cleaner, but it correctly falls through to the standard JSON decode for all non-Responses requests. Deferring to a framework-wide `decodeStreamLine` refactor is reasonable.",
    "",
    "---",
    "",
    h + h + h + " Remaining \u2014 minor coupling (low severity)",
    "",
    "**`Sources/OpenAI/OpenAI+ResponseRequest.swift`, line 704**",
    "",
    "```swift",
    "self.name = ChatCompletionRequest.ResponseFormat.JSONSchemaFormat.sanitize(name: name)",
    "```",
    "",
    "`ResponseRequest.TextConfig.Format.JSONSchemaFormat` calls a static method on its Chat Completions sibling to reuse name-sanitization logic (strip non-alphanumeric chars, truncate to 64, fall back to `\"structured_response\"`). Both types live in the same module so there is no visibility issue today, but the asymmetric dependency means `ResponseRequest` would silently fail to compile if `ChatCompletionRequest.ResponseFormat` is ever renamed or restructured. Extracting `sanitize(name:)` to a module-level helper eliminates the coupling at low cost.",
    "",
    "---",
    "",
    "*Reviewed by [Claude Code](https://claude.ai/code) \u00b7 Model: claude-sonnet-4-6*",
]

body = "\n".join(body_parts)

payload = __import__('json').dumps({"body": body})
result = subprocess.run(
    ["kh", "api", "--method", "PATCH",
     "/repos/rchatham/LangTools.swift/issues/comments/4795953792",
     "--input", "-", "-i"],
    input=payload.encode(),
    capture_output=True
)
print(result.stdout.decode().split("\n")[0])
if result.stderr:
    print(result.stderr.decode())
