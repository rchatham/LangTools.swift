//
//  RichResultDiagnostics.swift
//  LangTools
//
//  DEBUG-only, privacy-safe diagnostics for rich tool/agent result parsing.
//
//  This type is compiled out of release builds (`#if DEBUG`). Its purpose is to
//  make "why did my structured card not render?" diagnosable without ever
//  emitting raw payloads, prompts, response content, schema bodies, error
//  descriptions, arbitrary coding keys, custom model identifiers, or schema
//  titles. Every classifier maps a runtime string through a closed, finite
//  allowlist; unrecognized strings fall through to a fixed `.other`/`.redacted`
//  label and are never echoed into log output.
//
//  Call sites must wrap emission in `#if DEBUG` and use the enum-returning
//  classifiers plus the fixed-label formatters below. Formatters interpolate
//  only closed enum raw values, booleans rendered as "yes"/"no", integers
//  (byte counts, depths, item counts), and the random trace identifier — never
//  caller-supplied strings.
//

import Foundation

#if DEBUG

public enum RichResultDiagnostics {

    /// Fixed prefix for every diagnostic line. Grep/filter on this in Xcode.
    public static let prefix = "[RichResult]"

    // MARK: - Closed labels

    /// Closed agent label. Unknown agent names map to `.other` and are never printed.
    public enum AgentLabel: String, CaseIterable, Sendable {
        case calendar
        case calendarRead
        case calendarWrite
        case calendarPermission
        case weather
        case contacts
        case reminder
        case research
        case maps
        case pdf
        case finance
        case homeKit
        case fileSystem
        case openTable
        case codeExecution
        case other

        /// Maps a runtime agent name through the closed allowlist. Returns `.other`
        /// for anything not explicitly listed, including custom/secret identifiers.
        public static func label(for name: String) -> AgentLabel {
            switch name {
            case "calendarAgent": return .calendar
            case "calendarReadAgent": return .calendarRead
            case "calendarWriteAgent": return .calendarWrite
            case "calendarPermissionAgent": return .calendarPermission
            case "weatherAgent": return .weather
            case "contactsAgent", "contactsReadAgent", "contactsWriteAgent", "contactsPermissionAgent":
                return .contacts
            case "reminderAgent", "reminderReadAgent", "reminderWriteAgent", "reminderPermissionAgent":
                return .reminder
            case "researchAgent": return .research
            case "mapsAgent", "mapsSearchAgent", "mapsDirectionsAgent", "mapsPermissionAgent":
                return .maps
            case "pdfAgent": return .pdf
            case "financeAgent", "financeReadAgent", "financeWriteAgent", "financeAnalysisAgent":
                return .finance
            case "homeKitAgent", "homeKitReadAgent", "homeKitControlAgent", "homeKitPermissionAgent":
                return .homeKit
            case "fileSystemAgent", "fileSystemReadAgent", "fileSystemWriteAgent", "fileSystemPermissionAgent":
                return .fileSystem
            case "openTableAgent", "openTableSearchAgent", "openTableReservationAgent", "openTablePermissionAgent":
                return .openTable
            case "codeExecutionAgent": return .codeExecution
            default: return .other
            }
        }
    }

    /// Closed card-type label. Unknown card types map to `.other` and are never printed.
    public enum CardTypeLabel: String, CaseIterable, Sendable {
        case calendarEvent
        case event
        case weather
        case contact
        case location
        case finance
        case other

        public static func label(for cardType: String) -> CardTypeLabel {
            switch cardType {
            case "calendarEvent": return .calendarEvent
            case "event": return .event
            case "weather": return .weather
            case "contact": return .contact
            case "location": return .location
            case "finance": return .finance
            default: return .other
            }
        }
    }

    /// Closed provider/route label. Unknown values map to `.other` and are never printed.
    public enum ProviderLabel: String, CaseIterable, Sendable {
        case openAI
        case codex
        case anthropic
        case claudeCode
        case xAI
        case gemini
        case ollama
        case other

        /// Maps a closed `ModelRoute` raw value (e.g. `"openai"`, `"claude-code"`).
        public static func label(forRoute rawValue: String) -> ProviderLabel {
            switch rawValue {
            case "openai": return .openAI
            case "codex": return .codex
            case "anthropic": return .anthropic
            case "claude-code": return .claudeCode
            case "xai": return .xAI
            case "gemini": return .gemini
            case "ollama": return .ollama
            default: return .other
            }
        }

        /// Maps a provider dynamic type name (e.g. `"Anthropic"`) to a safe label.
        /// The type name is used only as a lookup key and is never printed.
        public static func label(forProviderTypeName typeName: String) -> ProviderLabel {
            switch typeName {
            case "OpenAI": return .openAI
            case "Anthropic": return .anthropic
            case "XAI": return .xAI
            case "Gemini": return .gemini
            case "Ollama": return .ollama
            default: return .other
            }
        }
    }

    /// Closed known-model allowlist. Only exact built-in model identifiers are
    /// named; custom/unknown model IDs map to `.custom` and are never printed.
    /// Raw values are compile-time constants (the known slugs), never the runtime
    /// slug itself.
    public enum ModelLabel: String, CaseIterable, Sendable {
        case gpt_4o = "gpt-4o"
        case gpt_4o_mini = "gpt-4o-mini"
        case gpt_4_1 = "gpt-4.1"
        case gpt_4_1_mini = "gpt-4.1-mini"
        case gpt_4 = "gpt-4"
        case gpt_4_turbo = "gpt-4-turbo"
        case gpt_3_5_turbo = "gpt-3.5-turbo"
        case gpt_5 = "gpt-5"
        case gpt_5_mini = "gpt-5-mini"
        case gpt_5_nano = "gpt-5-nano"
        case o1
        case o1_mini = "o1-mini"
        case o3
        case o3_mini = "o3-mini"
        case o4_mini = "o4-mini"
        case claude_opus_4_6 = "claude-opus-4-6"
        case claude_sonnet_4_6 = "claude-sonnet-4-6"
        case claude_opus_4_5 = "claude-opus-4-5"
        case claude_sonnet_4_5 = "claude-sonnet-4-5"
        case claude_haiku_4_5 = "claude-haiku-4-5"
        case claude_opus_4_1 = "claude-opus-4-1"
        case claude_sonnet_4 = "claude-sonnet-4"
        case claude_3_7_sonnet = "claude-3-7-sonnet"
        case claude_3_5_sonnet = "claude-3-5-sonnet"
        case grok_4 = "grok-4"
        case grok_4_fast_reasoning = "grok-4-fast-reasoning"
        case grok_4_fast_non_reasoning = "grok-4-fast-non-reasoning"
        case grok_3 = "grok-3"
        case grok_3_mini = "grok-3-mini"
        case gemini_3_pro_preview = "gemini-3-pro-preview"
        case gemini_3_flash_preview = "gemini-3-flash-preview"
        case gemini_3_pro = "gemini-3-pro"
        case gemini_3_flash = "gemini-3-flash"
        case gemini_2_5_flash = "gemini-2.5-flash"
        case gemini_2_5_pro = "gemini-2.5-pro"
        case gemini_2_0_flash = "gemini-2.0-flash"
        // OpenAI — additional distinct chat models
        case chatgpt_4o_latest = "chatgpt-4o-latest"
        case gpt_4o_search_preview = "gpt-4o-search-preview"
        case gpt_4o_mini_search_preview = "gpt-4o-mini-search-preview"
        case gpt_4_1_nano = "gpt-4.1-nano"
        case gpt_5_pro = "gpt-5-pro"
        case gpt_5_1 = "gpt-5.1"
        case gpt_5_2 = "gpt-5.2"
        case gpt_5_2_pro = "gpt-5.2-pro"
        case gpt_5_3 = "gpt-5.3"
        case gpt_5_4 = "gpt-5.4"
        case gpt_5_4_pro = "gpt-5.4-pro"
        case gpt_5_4_mini = "gpt-5.4-mini"
        case gpt_5_4_nano = "gpt-5.4-nano"
        case gpt_5_5 = "gpt-5.5"
        case gpt_5_5_pro = "gpt-5.5-pro"
        case gpt_5_3_codex_spark = "gpt-5.3-codex-spark"
        case o1_preview = "o1-preview"
        case o3_pro = "o3-pro"
        // Anthropic — additional families
        case claude_opus_4 = "claude-opus-4"
        case claude_3_haiku = "claude-3-haiku"
        case claude_3_5_haiku = "claude-3-5-haiku"
        case claude_3_opus = "claude-3-opus"
        case claude_3_sonnet = "claude-3-sonnet"
        // xAI — additional chat models
        case grok_4_1_fast_reasoning = "grok-4-1-fast-reasoning"
        case grok_4_1_fast_non_reasoning = "grok-4-1-fast-non-reasoning"
        case grok_code_fast_1 = "grok-code-fast-1"
        case grok_2_vision_1212 = "grok-2-vision-1212"
        case grok_2_1212 = "grok-2-1212"
        case grok_beta = "grok-beta"
        // Gemini — additional models
        case gemini_3_1_pro = "gemini-3.1-pro"
        case gemini_2_5_flash_lite = "gemini-2.5-flash-lite"
        case gemini_2_0_flash_lite = "gemini-2.0-flash-lite"
        case gemini_1_5_flash = "gemini-1.5-flash"
        case gemini_1_5_flash_8b = "gemini-1.5-flash-8b"
        case gemini_1_5_pro = "gemini-1.5-pro"
        case gemini_1_0_pro = "gemini-1.0-pro"
        case custom

        /// Exact built-in model identifiers (canonical, dated, and `-latest` forms)
        /// mapped to their family label. Anything absent is `.custom`. Keys are
        /// closed, compile-time literals copied from the provider enum definitions.
        private static let knownAliases: [String: ModelLabel] = [
            // OpenAI chat
            "gpt-3.5-turbo": .gpt_3_5_turbo,
            "gpt-3.5-turbo-0301": .gpt_3_5_turbo,
            "gpt-3.5-turbo-1106": .gpt_3_5_turbo,
            "gpt-3.5-turbo-16k": .gpt_3_5_turbo,
            "gpt-3.5-turbo-instruct": .gpt_3_5_turbo,
            "gpt-4": .gpt_4,
            "gpt-4-turbo": .gpt_4_turbo,
            "gpt-4-0613": .gpt_4,
            "gpt-4-1106-preview": .gpt_4,
            "gpt-4-vision-preview": .gpt_4,
            "gpt-4-32k-0613": .gpt_4,
            "gpt-4o": .gpt_4o,
            "gpt-4o-2024-05-13": .gpt_4o,
            "gpt-4o-2024-08-06": .gpt_4o,
            "gpt-4o-2024-11-20": .gpt_4o,
            "gpt-4o-mini": .gpt_4o_mini,
            "gpt-4o-mini-2024-07-18": .gpt_4o_mini,
            "chatgpt-4o-latest": .chatgpt_4o_latest,
            "gpt-4o-search-preview": .gpt_4o_search_preview,
            "gpt-4o-mini-search-preview": .gpt_4o_mini_search_preview,
            "gpt-4.1": .gpt_4_1,
            "gpt-4.1-mini": .gpt_4_1_mini,
            "gpt-4.1-nano": .gpt_4_1_nano,
            "gpt-5": .gpt_5,
            "gpt-5-mini": .gpt_5_mini,
            "gpt-5-nano": .gpt_5_nano,
            "gpt-5-pro": .gpt_5_pro,
            "gpt-5.1": .gpt_5_1,
            "gpt-5.2": .gpt_5_2,
            "gpt-5.2-pro": .gpt_5_2_pro,
            "gpt-5.3": .gpt_5_3,
            "gpt-5.4": .gpt_5_4,
            "gpt-5.4-pro": .gpt_5_4_pro,
            "gpt-5.4-mini": .gpt_5_4_mini,
            "gpt-5.4-nano": .gpt_5_4_nano,
            "gpt-5.5": .gpt_5_5,
            "gpt-5.5-pro": .gpt_5_5_pro,
            "gpt-5.3-codex-spark": .gpt_5_3_codex_spark,
            "o1": .o1,
            "o1-mini": .o1_mini,
            "o1-preview": .o1_preview,
            "o3": .o3,
            "o3-pro": .o3_pro,
            "o3-mini": .o3_mini,
            "o4-mini": .o4_mini,
            // Anthropic
            "claude-opus-4-6": .claude_opus_4_6,
            "claude-opus-4-6-20260205": .claude_opus_4_6,
            "claude-sonnet-4-6": .claude_sonnet_4_6,
            "claude-sonnet-4-6-20260217": .claude_sonnet_4_6,
            "claude-opus-4-5-20251101": .claude_opus_4_5,
            "claude-sonnet-4-5-latest": .claude_sonnet_4_5,
            "claude-sonnet-4-5-20250929": .claude_sonnet_4_5,
            "claude-haiku-4-5-latest": .claude_haiku_4_5,
            "claude-haiku-4-5-20251001": .claude_haiku_4_5,
            "claude-opus-4-1-latest": .claude_opus_4_1,
            "claude-opus-4-1-20250805": .claude_opus_4_1,
            "claude-opus-4-20250514": .claude_opus_4,
            "claude-sonnet-4-20250514": .claude_sonnet_4,
            "claude-3-haiku-20240307": .claude_3_haiku,
            "claude-3-7-sonnet-20250219": .claude_3_7_sonnet,
            "claude-3-5-haiku-20241022": .claude_3_5_haiku,
            "claude-3-5-sonnet-latest": .claude_3_5_sonnet,
            "claude-3-5-sonnet-20241022": .claude_3_5_sonnet,
            "claude-3-5-sonnet-20240620": .claude_3_5_sonnet,
            "claude-3-opus-latest": .claude_3_opus,
            "claude-3-opus-20240229": .claude_3_opus,
            "claude-3-sonnet-20240229": .claude_3_sonnet,
            // xAI chat
            "grok-4-1-fast-reasoning": .grok_4_1_fast_reasoning,
            "grok-4-1-fast-non-reasoning": .grok_4_1_fast_non_reasoning,
            "grok-4-fast-reasoning": .grok_4_fast_reasoning,
            "grok-4-fast-non-reasoning": .grok_4_fast_non_reasoning,
            "grok-4-0709": .grok_4,
            "grok-3": .grok_3,
            "grok-3-mini": .grok_3_mini,
            "grok-code-fast-1": .grok_code_fast_1,
            "grok-2-vision-1212": .grok_2_vision_1212,
            "grok-2-1212": .grok_2_1212,
            "grok-beta": .grok_beta,
            // Gemini chat
            "gemini-3-pro": .gemini_3_pro,
            "gemini-3-pro-preview": .gemini_3_pro_preview,
            "gemini-3-flash": .gemini_3_flash,
            "gemini-3-flash-preview": .gemini_3_flash_preview,
            "gemini-3.1-pro": .gemini_3_1_pro,
            "gemini-2.5-flash": .gemini_2_5_flash,
            "gemini-2.5-flash-lite": .gemini_2_5_flash_lite,
            "gemini-2.5-pro": .gemini_2_5_pro,
            "gemini-2.0-flash": .gemini_2_0_flash,
            "gemini-2.0-flash-lite": .gemini_2_0_flash_lite,
            "gemini-1.5-flash": .gemini_1_5_flash,
            "gemini-1.5-flash-8b": .gemini_1_5_flash_8b,
            "gemini-1.5-pro": .gemini_1_5_pro,
            "gemini-1.0-pro": .gemini_1_0_pro,
        ]

        /// Maps a runtime slug (or a `route/slug` composite) through the closed
        /// allowlist. A known route prefix is stripped at most once; an unknown
        /// prefix or any custom slug yields `.custom`. The raw slug is never echoed.
        public static func label(for slug: String) -> ModelLabel {
            let normalized: String
            if let slashIndex = slug.firstIndex(of: "/") {
                let prefix = String(slug[..<slashIndex])
                switch prefix {
                case "openai", "anthropic", "xai", "gemini", "ollama", "codex", "claude-code":
                    normalized = String(slug[slug.index(after: slashIndex)...])
                default:
                    return .custom
                }
            } else {
                normalized = slug
            }
            return knownAliases[normalized] ?? .custom
        }
    }

    /// Closed structured-output type label. Unknown type names map to `.other`.
    public enum TypeLabel: String, CaseIterable, Sendable {
        case calendarAgentResponse
        case calendarEventData
        case weatherCardData
        case contactCardData
        case locationCardData
        case financeCardData
        case other

        public static func label(forType type: Any.Type) -> TypeLabel {
            switch String(describing: type) {
            case "CalendarAgentResponse": return .calendarAgentResponse
            case "CalendarEventData": return .calendarEventData
            case "WeatherCardData": return .weatherCardData
            case "ContactCardData": return .contactCardData
            case "LocationCardData": return .locationCardData
            case "FinanceCardData": return .financeCardData
            default: return .other
            }
        }
    }

    /// Closed calendar field allowlist. Unknown coding keys map to `.redacted`.
    public enum FieldLabel: String, CaseIterable, Sendable {
        case events
        case message
        case title
        case startDate
        case endDate
        case location
        case notes
        case isAllDay
        case calendarName
        case eventIdentifier
        case redacted

        public static func label(for key: String) -> FieldLabel {
            switch key {
            case "events": return .events
            case "message": return .message
            case "title": return .title
            case "startDate": return .startDate
            case "endDate": return .endDate
            case "location": return .location
            case "notes": return .notes
            case "isAllDay": return .isAllDay
            case "calendarName": return .calendarName
            case "eventIdentifier": return .eventIdentifier
            default: return .redacted
            }
        }
    }

    // MARK: - Outcome / shape / category labels

    /// Coarse shape classification of a raw result string. Static prefix checks only;
    /// never parses or exposes payload content.
    public enum ResultShape: String, Sendable {
        case empty
        case fenced
        case object
        case array
        case text

        public static func classify(_ raw: String) -> ResultShape {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .empty }
            if trimmed.hasPrefix("```") { return .fenced }
            if trimmed.hasPrefix("{") { return .object }
            if trimmed.hasPrefix("[") { return .array }
            return .text
        }
    }

    /// Fixed category for a structured-output decoding failure. Derived only from
    /// the `DecodingError` case, never from its context description (which may
    /// contain untrusted content).
    public enum DecodeFailureCategory: String, Sendable {
        case keyNotFound
        case typeMismatch
        case valueNotFound
        case dataCorrupted
        case other

        public static func classify(_ error: any Error) -> DecodeFailureCategory {
            guard let decodingError = underlyingDecodingError(error) else { return .other }
            switch decodingError {
            case .keyNotFound: return .keyNotFound
            case .typeMismatch: return .typeMismatch
            case .valueNotFound: return .valueNotFound
            case .dataCorrupted: return .dataCorrupted
            @unknown default: return .other
            }
        }
    }

    /// Allowlisted coding path extracted from a decoding failure. Only known
    /// calendar field names are retained; all other keys render as `.redacted`.
    /// Depth is the number of path components (capped semantics: every component
    /// is a label, no raw key strings are retained).
    public struct CodingPath: Sendable {
        public let depth: Int
        public let components: [FieldLabel]

        public init(depth: Int, components: [FieldLabel]) {
            self.depth = depth
            self.components = components
        }
    }

    public static func codingPath(for error: any Error) -> CodingPath {
        guard let decodingError = underlyingDecodingError(error) else {
            return CodingPath(depth: 0, components: [])
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            var components = context.codingPath.map { FieldLabel.label(for: $0.stringValue) }
            components.append(FieldLabel.label(for: key.stringValue))
            return CodingPath(depth: components.count, components: components)
        case .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .dataCorrupted(let context):
            let components = context.codingPath.map { FieldLabel.label(for: $0.stringValue) }
            return CodingPath(depth: components.count, components: components)
        @unknown default:
            return CodingPath(depth: 0, components: [])
        }
    }

    /// Where an agent's effective schema came from.
    public enum SchemaSource: String, Sendable {
        case agent
        case context
        case none
    }

    /// Registry parse outcome.
    public enum ParseOutcome: String, Sendable {
        case registryMiss
        case decodeNil
        case emptyItems
        case parsed
    }

    /// Presentation outcome for a completed tool/agent result.
    public enum PresentationOutcome: String, Sendable {
        case attached
        case attachMissed
        case standalone
        case legacy
        case raw
    }

    /// Agent vs tool namespace.
    public enum Namespace: String, Sendable {
        case agent
        case tool
    }

    /// Fixed category for a narrowed agent error log (no error interpolation).
    public enum AgentErrorCategory: String, Sendable {
        case transfer
        case execution
    }

    // MARK: - Trace IDs

    /// Opaque random trace identifier. Its initializer is private so callers can
    /// only obtain random instances — an arbitrary string can never be injected
    /// into a diagnostic line. Renders as random uppercase hex.
    public struct TraceID: Sendable, Equatable {
        fileprivate let value: String

        private init() {
            value = String(UInt32.random(in: 0 ..< UInt32.max), radix: 16, uppercase: true)
        }

        /// Generates a fresh random trace identifier.
        public static func random() -> TraceID {
            TraceID()
        }
    }

    // MARK: - Formatters

    public static func agentRequestLog(
        traceID: TraceID,
        agent: AgentLabel,
        model: ModelLabel,
        provider: ProviderLabel,
        schemaSource: SchemaSource,
        schemaRequested: Bool,
        requestSupportsStructuredOutput: Bool,
        schemaApplied: Bool
    ) -> String {
        "\(prefix)[agent-request] trace=\(traceID.value) agent=\(agent.rawValue) model=\(model.rawValue) provider=\(provider.rawValue) schema=\(schemaSource.rawValue) requested=\(schemaRequested ? "yes" : "no") supportsStructuredOutput=\(requestSupportsStructuredOutput ? "yes" : "no") applied=\(schemaApplied ? "yes" : "no")"
    }

    public static func agentCompletionLog(
        traceID: TraceID,
        agent: AgentLabel,
        shape: ResultShape,
        byteCount: Int,
        isError: Bool
    ) -> String {
        "\(prefix)[agent-complete] trace=\(traceID.value) agent=\(agent.rawValue) shape=\(shape.rawValue) bytes=\(byteCount) error=\(isError ? "yes" : "no")"
    }

    public static func agentErrorLog(
        traceID: TraceID,
        agent: AgentLabel,
        category: AgentErrorCategory
    ) -> String {
        "\(prefix)[agent-error] trace=\(traceID.value) agent=\(agent.rawValue) category=\(category.rawValue)"
    }

    public static func decodeFailureLog(
        type: TypeLabel,
        category: DecodeFailureCategory,
        path: CodingPath,
        byteCount: Int,
        shape: ResultShape
    ) -> String {
        let renderedPath = path.components.map(\.rawValue).joined(separator: ".")
        return "\(prefix)[decode] type=\(type.rawValue) category=\(category.rawValue) depth=\(path.depth) path=\(renderedPath) bytes=\(byteCount) shape=\(shape.rawValue)"
    }

    public static func registryLog(
        namespace: Namespace,
        agent: AgentLabel?,
        outcome: ParseOutcome,
        cardType: CardTypeLabel? = nil,
        itemCount: Int? = nil
    ) -> String {
        var line = "\(prefix)[registry] namespace=\(namespace.rawValue)"
        if let agent { line += " agent=\(agent.rawValue)" }
        line += " outcome=\(outcome.rawValue)"
        if let cardType { line += " cardType=\(cardType.rawValue)" }
        if let itemCount { line += " count=\(itemCount)" }
        return line
    }

    public static func presentationLog(
        namespace: Namespace,
        agent: AgentLabel?,
        outcome: PresentationOutcome,
        history: Bool,
        rich: Bool
    ) -> String {
        var line = "\(prefix)[presentation] namespace=\(namespace.rawValue)"
        if let agent { line += " agent=\(agent.rawValue)" }
        line += " outcome=\(outcome.rawValue) history=\(history ? "yes" : "no") rich=\(rich ? "yes" : "no")"
        return line
    }

    public static func modelSelectionLog(
        route: ProviderLabel,
        model: ModelLabel,
        override: ProviderLabel?,
        overrideModel: ModelLabel?,
        rich: Bool,
        history: Bool
    ) -> String {
        var line = "\(prefix)[model] route=\(route.rawValue) model=\(model.rawValue)"
        if let override, let overrideModel {
            line += " override=\(override.rawValue) overrideModel=\(overrideModel.rawValue)"
        } else {
            line += " override=none"
        }
        line += " rich=\(rich ? "yes" : "no") history=\(history ? "yes" : "no")"
        return line
    }

    // MARK: - Emission helpers

    /// Emits a decode-failure diagnostic from the `StructuredOutput` decode path.
    /// `type` is only ever rendered through `TypeLabel`; `raw` contributes only
    /// its byte count and coarse shape; `error` contributes only its category and
    /// allowlisted coding path.
    public static func logDecodeFailure(for type: Any.Type, raw: String, error: any Error) {
        let path = codingPath(for: error)
        print(decodeFailureLog(
            type: TypeLabel.label(forType: type),
            category: DecodeFailureCategory.classify(error),
            path: path,
            byteCount: raw.utf8.count,
            shape: ResultShape.classify(raw)
        ))
    }

    // MARK: - Private helpers

    /// Unwraps a `DecodingError`, including through
    /// `StructuredOutputError.decodingFailed`, without ever reading context
    /// descriptions.
    private static func underlyingDecodingError(_ error: any Error) -> DecodingError? {
        if let decodingError = error as? DecodingError { return decodingError }
        if case StructuredOutputError.decodingFailed(let underlying) = error {
            return underlyingDecodingError(underlying)
        }
        return nil
    }
}

#endif
