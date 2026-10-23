//
//  RichResultDiagnosticsTests.swift
//  LangToolsTests
//

import XCTest
import LangTools
import OpenAI
import Anthropic

/// Privacy-safety and correctness tests for the DEBUG-only rich-result
/// diagnostics formatter. These assert that arbitrary runtime strings — including
/// ASCII-looking secret identifiers and malicious decode-error content — are
/// always mapped through a closed allowlist and never echoed into log output.
final class RichResultDiagnosticsTests: XCTestCase {

    // MARK: - Adversarial identifiers

    func testAgentLabelRedactsASCIILookingSecretIdentifiers() {
        // API keys and other secrets are commonly pure ASCII; a charset allowlist
        // would leak them. The closed known-agent list must map them to `.other`.
        for secret in ["sk-proj-abcdef1234567890", "abcd1234", "gpt-4o-secret-key", "Bearer-token-xyz"] {
            XCTAssertEqual(RichResultDiagnostics.AgentLabel.label(for: secret), .other, "\(secret) must not be echoed")
        }
    }

    func testKnownCalendarAgentLabels() {
        XCTAssertEqual(RichResultDiagnostics.AgentLabel.label(for: "calendarAgent"), .calendar)
        XCTAssertEqual(RichResultDiagnostics.AgentLabel.label(for: "calendarReadAgent"), .calendarRead)
        XCTAssertEqual(RichResultDiagnostics.AgentLabel.label(for: "calendarWriteAgent"), .calendarWrite)
        XCTAssertEqual(RichResultDiagnostics.AgentLabel.label(for: "calendarPermissionAgent"), .calendarPermission)
    }

    func testFieldLabelRedactsUnknownKeys() {
        XCTAssertEqual(RichResultDiagnostics.FieldLabel.label(for: "apiKey"), .redacted)
        XCTAssertEqual(RichResultDiagnostics.FieldLabel.label(for: "sk-secret-123"), .redacted)
        XCTAssertEqual(RichResultDiagnostics.FieldLabel.label(for: "BearerToken"), .redacted)
    }

    func testKnownCalendarFieldLabels() {
        XCTAssertEqual(RichResultDiagnostics.FieldLabel.label(for: "startDate"), .startDate)
        XCTAssertEqual(RichResultDiagnostics.FieldLabel.label(for: "endDate"), .endDate)
        XCTAssertEqual(RichResultDiagnostics.FieldLabel.label(for: "events"), .events)
        XCTAssertEqual(RichResultDiagnostics.FieldLabel.label(for: "message"), .message)
        XCTAssertEqual(RichResultDiagnostics.FieldLabel.label(for: "eventIdentifier"), .eventIdentifier)
    }

    func testCardTypeLabelRedactsUnknown() {
        XCTAssertEqual(RichResultDiagnostics.CardTypeLabel.label(for: "calendarEvent"), .calendarEvent)
        XCTAssertEqual(RichResultDiagnostics.CardTypeLabel.label(for: "custom-card-<script>"), .other)
    }

    func testProviderRouteLabelRedactsUnknown() {
        XCTAssertEqual(RichResultDiagnostics.ProviderLabel.label(forRoute: "openai"), .openAI)
        XCTAssertEqual(RichResultDiagnostics.ProviderLabel.label(forRoute: "claude-code"), .claudeCode)
        XCTAssertEqual(RichResultDiagnostics.ProviderLabel.label(forRoute: "anthropic"), .anthropic)
        XCTAssertEqual(RichResultDiagnostics.ProviderLabel.label(forRoute: "custom-provider"), .other)
    }

    func testProviderTypeNameLabelRedactsUnknown() {
        XCTAssertEqual(RichResultDiagnostics.ProviderLabel.label(forProviderTypeName: "Anthropic"), .anthropic)
        XCTAssertEqual(RichResultDiagnostics.ProviderLabel.label(forProviderTypeName: "CustomProvider"), .other)
    }

    // MARK: - Shape classification

    func testResultShapeClassification() {
        XCTAssertEqual(RichResultDiagnostics.ResultShape.classify(""), .empty)
        XCTAssertEqual(RichResultDiagnostics.ResultShape.classify("   \n  "), .empty)
        XCTAssertEqual(RichResultDiagnostics.ResultShape.classify("```json\n{}"), .fenced)
        XCTAssertEqual(RichResultDiagnostics.ResultShape.classify("{}"), .object)
        XCTAssertEqual(RichResultDiagnostics.ResultShape.classify("[]"), .array)
        XCTAssertEqual(RichResultDiagnostics.ResultShape.classify("plain text"), .text)
        XCTAssertEqual(RichResultDiagnostics.ResultShape.classify("  { \"a\": 1 }  "), .object)
    }

    // MARK: - Decode failure classification

    func testClassifyKeyNotFoundFromRealDecode() throws {
        struct Event: Decodable {
            let title: String
            let startDate: String
            let endDate: String
        }
        do {
            _ = try JSONDecoder().decode(Event.self, from: Data(#"{"title":"x"}"#.utf8))
            XCTFail("expected decode failure")
        } catch {
            XCTAssertEqual(RichResultDiagnostics.DecodeFailureCategory.classify(error), .keyNotFound)
            let path = RichResultDiagnostics.codingPath(for: error)
            XCTAssertEqual(path.depth, 1)
            XCTAssertEqual(path.components, [.startDate])
        }
    }

    func testClassifyDataCorrupted() {
        let context = DecodingError.Context(codingPath: [], debugDescription: "malformed")
        let error = DecodingError.dataCorrupted(context)
        XCTAssertEqual(RichResultDiagnostics.DecodeFailureCategory.classify(error), .dataCorrupted)
    }

    func testClassifyUnwrapsStructuredOutputError() {
        let context = DecodingError.Context(codingPath: [], debugDescription: "x")
        let wrapped = StructuredOutputError.decodingFailed(DecodingError.dataCorrupted(context))
        XCTAssertEqual(RichResultDiagnostics.DecodeFailureCategory.classify(wrapped), .dataCorrupted)
    }

    func testCodingPathRedactsUnknownCodingKey() {
        let secretKey = "BearerToken-secret-value"
        let key = RawCodingKey(stringValue: secretKey)!
        let context = DecodingError.Context(codingPath: [key], debugDescription: "untrusted")
        let error = DecodingError.keyNotFound(key, context)

        let path = RichResultDiagnostics.codingPath(for: error)
        XCTAssertEqual(path.depth, 2)
        XCTAssertTrue(path.components.allSatisfy { $0 == .redacted })
    }

    // MARK: - Formatter never echoes secrets

    func testAgentRequestLogNeverEchoesSecretAgentName() {
        let secret = "sk-proj-abcdef1234567890"
        let log = RichResultDiagnostics.agentRequestLog(
            traceID: .random(),
            agent: .label(for: secret),
            model: .label(for: secret),
            provider: .other,
            schemaSource: .none,
            schemaRequested: false,
            requestSupportsStructuredOutput: false,
            schemaApplied: false
        )
        XCTAssertFalse(log.contains(secret))
        XCTAssertTrue(log.contains("agent=other"))
        XCTAssertTrue(log.contains("model=custom"))
        XCTAssertTrue(log.hasPrefix("[RichResult][agent-request]"))
    }

    func testDecodeFailureLogNeverEchoesMaliciousDescriptionOrKeys() {
        let secret = "super-secret-api-key-value"
        let secretKey = "Authorization"
        let key = RawCodingKey(stringValue: secretKey)!
        let context = DecodingError.Context(
            codingPath: [key],
            debugDescription: "offending value: \(secret)"
        )
        let error = DecodingError.keyNotFound(key, context)

        let log = RichResultDiagnostics.decodeFailureLog(
            type: .other,
            category: .classify(error),
            path: RichResultDiagnostics.codingPath(for: error),
            byteCount: 128,
            shape: .object
        )
        XCTAssertFalse(log.contains(secret))
        XCTAssertFalse(log.contains(secretKey))
        XCTAssertFalse(log.contains("offending"))
        XCTAssertTrue(log.contains("path=redacted.redacted"))
    }

    func testRegistryAndPresentationLogsUseFixedLabels() {
        let registry = RichResultDiagnostics.registryLog(
            namespace: .agent, agent: .label(for: "calendarAgent"), outcome: .decodeNil
        )
        XCTAssertEqual(registry, "[RichResult][registry] namespace=agent agent=calendar outcome=decodeNil")

        let presentation = RichResultDiagnostics.presentationLog(
            namespace: .agent, agent: .label(for: "calendarAgent"), outcome: .raw,
            history: true, rich: true
        )
        XCTAssertEqual(
            presentation,
            "[RichResult][presentation] namespace=agent agent=calendar outcome=raw history=yes rich=yes"
        )
    }

    func testModelLabelRedactsASCIISecretAndUnknownModel() {
        for secret in ["sk-proj-abcdef1234567890", "custom-ollama-model", "gpt-4o-custom"] {
            XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: secret), .custom)
        }
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "gpt-4o"), .gpt_4o)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "claude-sonnet-4-6"), .claude_sonnet_4_6)
    }

    func testTraceIDIsRandomHexOnly() {
        var traces = Set<String>()
        for _ in 0..<20 {
            let log = RichResultDiagnostics.agentErrorLog(
                traceID: .random(), agent: .calendar, category: .execution
            )
            guard let range = log.range(of: "trace=") else {
                XCTFail("missing trace token"); return
            }
            let suffix = String(log[range.upperBound...])
            let token = suffix.split(separator: " ").first.map(String.init) ?? ""
            XCTAssertFalse(token.isEmpty)
            XCTAssertNotNil(
                token.range(of: "^[0-9A-F]+$", options: .regularExpression),
                "trace must be uppercase hex"
            )
            traces.insert(token)
        }
        XCTAssertGreaterThan(traces.count, 1, "trace IDs should be random, not constant")
    }

    func testAttachMissedPresentationOutcomeIsFixedLabel() {
        let log = RichResultDiagnostics.presentationLog(
            namespace: .agent, agent: .label(for: "calendarAgent"), outcome: .attachMissed,
            history: true, rich: true
        )
        XCTAssertEqual(
            log,
            "[RichResult][presentation] namespace=agent agent=calendar outcome=attachMissed history=yes rich=yes"
        )
    }

    func testActualCalendarMissingStartDatePath() {
        struct CalendarEvent: Decodable {
            let title: String
            let startDate: String
            let endDate: String
        }
        struct CalendarResponse: Decodable {
            let events: [CalendarEvent]
            let message: String?
        }
        do {
            _ = try JSONDecoder().decode(
                CalendarResponse.self,
                from: Data(#"{"events":[{"title":"x","endDate":"2026-01-01T00:00:00Z"}],"message":null}"#.utf8)
            )
            XCTFail("expected decode failure")
        } catch {
            XCTAssertEqual(RichResultDiagnostics.DecodeFailureCategory.classify(error), .keyNotFound)
            let path = RichResultDiagnostics.codingPath(for: error)
            XCTAssertEqual(path.depth, 3)
            XCTAssertEqual(path.components, [.events, .redacted, .startDate])
        }
    }

    // MARK: - Known model aliases (exact provider enum forms)

    func testDatedAndLatestAliasesMapToFamily() {
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "claude-opus-4-5-20251101"), .claude_opus_4_5)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "claude-sonnet-4-5-latest"), .claude_sonnet_4_5)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "claude-haiku-4-5-latest"), .claude_haiku_4_5)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "claude-opus-4-1-latest"), .claude_opus_4_1)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "claude-sonnet-4-20250514"), .claude_sonnet_4)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "claude-3-5-sonnet-latest"), .claude_3_5_sonnet)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "grok-4-0709"), .grok_4)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "gemini-3.1-pro"), .gemini_3_1_pro)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "gpt-4o-2024-08-06"), .gpt_4o)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "gpt-4o-mini-2024-07-18"), .gpt_4o_mini)
    }

    func testKnownModelAliasesMatchProviderEnums() {
        for model in Anthropic.Model.allCases {
            XCTAssertNotEqual(
                RichResultDiagnostics.ModelLabel.label(for: model.rawValue),
                .custom,
                "Anthropic known model '\(model.rawValue)' should not be custom"
            )
        }
        for model in OpenAI.Model.chatModels {
            XCTAssertNotEqual(
                RichResultDiagnostics.ModelLabel.label(for: model.rawValue),
                .custom,
                "OpenAI chat model '\(model.rawValue)' should not be custom"
            )
        }
    }

    func testKnownCompositeRouteSlug() {
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "openai/gpt-4o"), .gpt_4o)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "anthropic/claude-sonnet-4-6"), .claude_sonnet_4_6)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "codex/gpt-5.3-codex-spark"), .gpt_5_3_codex_spark)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "claude-code/claude-sonnet-4-6"), .claude_sonnet_4_6)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "gemini/gemini-3.1-pro"), .gemini_3_1_pro)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "xai/grok-4-0709"), .grok_4)
        XCTAssertEqual(RichResultDiagnostics.ModelLabel.label(for: "ollama/llama3"), .custom)
    }

    func testCustomASCIIAndSlashSecretRedacted() {
        for secret in [
            "sk-proj-abc123XYZ",
            "openai/sk-proj-abc",
            "custom/model-secret",
            "gpt-4o/custom-suffix",
            "my-provider/gpt-4o",
        ] {
            XCTAssertEqual(
                RichResultDiagnostics.ModelLabel.label(for: secret),
                .custom,
                "\(secret) must be redacted as custom"
            )
        }
    }
}

/// Minimal `CodingKey` for synthesizing untrusted decode errors in tests.
private struct RawCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}
