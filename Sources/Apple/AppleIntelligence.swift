//
//  AppleIntelligence.swift
//  LangTools
//
//  On-device text generation using Apple's Foundation Models framework.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools

/// On-device language provider backed by Apple's Foundation Models framework.
///
/// Conforms to `LangTools` so it can sit in a `LangToolchain` beside network
/// providers; `perform` and `stream` run on `LanguageModelSession` instead of
/// HTTP. The type compiles on every supported platform; generation needs
/// iOS/macOS/visionOS 26 with Apple Intelligence enabled (see `availability`).
public final class AppleIntelligence: LangTools, Sendable {
    public typealias Model = AppleIntelligenceModel
    public typealias ErrorResponse = AppleIntelligenceErrorResponse
    public typealias Message = LangToolsMessageImpl<LangToolsTextContent>

    /// Unused: generation happens on-device. Present to satisfy `LangTools`.
    public var session: URLSession { .shared }

    public init() {}

    public static var requestValidators: [(any LangToolsRequest) -> Bool] {
        [{ $0 is ChatRequest }]
    }

    /// Whether this OS ships the Foundation Models framework at all.
    public static var isSupportedOnThisOS: Bool {
        #if canImport(FoundationModels) && !os(watchOS) && !os(tvOS)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Runtime readiness of the on-device system language model.
    public static var availability: Availability {
        #if canImport(FoundationModels) && !os(watchOS) && !os(tvOS)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return FoundationModelsEngine.availability
        }
        #endif
        return .unavailable(.unsupportedOS)
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        throw AppleIntelligenceError.notAnHTTPProvider
    }

    public func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        guard let chatRequest = request as? ChatRequest else { throw LangToolsError.invalidArgument("Unsupported request type \(Request.self)") }
        let response = try await Self.respond(to: chatRequest)
        guard let typed = response as? Request.Response else { throw LangToolsError.invalidData }
        return typed
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error> {
        guard let chatRequest = request as? ChatRequest else {
            return AsyncThrowingStream { $0.finish(throwing: LangToolsError.invalidArgument("Unsupported request type \(Request.self)")) }
        }
        guard chatRequest.stream ?? true else {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let response = try await Self.respond(to: chatRequest)
                        if let typed = response as? Request.Response { continuation.yield(typed) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
        return Self.streamResponse(to: chatRequest).compactMapAsyncThrowingStream { $0 as? Request.Response }
    }

    public static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, responseSchema: JSONSchema?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        guard let model = model as? Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        guard tools?.isEmpty ?? true else { throw AppleIntelligenceError.toolCallingUnsupported }
        guard responseSchema == nil else { throw AppleIntelligenceError.structuredOutputUnsupported }
        return ChatRequest(model: model, messages: messages)
    }

    /// Whether `error` originated from Apple Intelligence generation: this
    /// provider's own errors or Foundation Models generation/tool-call errors.
    public static func isProviderError(_ error: Error) -> Bool {
        if error is AppleIntelligenceError { return true }
        #if canImport(FoundationModels) && !os(watchOS) && !os(tvOS)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return FoundationModelsEngine.isFrameworkError(error)
        }
        #endif
        return false
    }

    /// Text to emit for a streamed snapshot, given everything emitted so far.
    ///
    /// Foundation Models string snapshots carry the cumulative response and grow
    /// append-only. LangTools deltas cannot retract text, so if a snapshot ever
    /// rewrites earlier output only the part beyond what was already emitted is
    /// sent; re-sending the whole snapshot would duplicate it once deltas combine.
    static func streamDelta(emitted: String, snapshot: String) -> String {
        String(snapshot.dropFirst(emitted.count))
    }

    // MARK: - Engine dispatch

    private static func respond(to request: ChatRequest) async throws -> ChatResponse {
        #if canImport(FoundationModels) && !os(watchOS) && !os(tvOS)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return try await FoundationModelsEngine.respond(to: request)
        }
        #endif
        throw AppleIntelligenceError.unavailable(.unsupportedOS)
    }

    private static func streamResponse(to request: ChatRequest) -> AsyncThrowingStream<ChatResponse, Error> {
        #if canImport(FoundationModels) && !os(watchOS) && !os(tvOS)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return FoundationModelsEngine.streamResponse(to: request)
        }
        #endif
        return AsyncThrowingStream { $0.finish(throwing: AppleIntelligenceError.unavailable(.unsupportedOS)) }
    }
}

// MARK: - Model

/// System language models exposed by Foundation Models.
public enum AppleIntelligenceModel: String, Codable, CaseIterable, Sendable {
    /// `SystemLanguageModel.default`, the general-purpose on-device model.
    case onDevice = "on-device"

    /// Approximate context window shared by prompt, history, and response.
    public static let contextWindowTokens = 4_096
}

// MARK: - Availability

extension AppleIntelligence {
    public enum Availability: Equatable, Sendable {
        case available
        case unavailable(UnavailableReason)
    }

    public enum UnavailableReason: Equatable, Sendable {
        /// The OS predates Foundation Models (requires iOS/macOS/visionOS 26).
        case unsupportedOS
        /// Hardware does not support Apple Intelligence.
        case deviceNotEligible
        /// Apple Intelligence is supported but turned off in Settings.
        case appleIntelligenceNotEnabled
        /// The model is still downloading or otherwise not ready yet.
        case modelNotReady
        case unknown

        public var message: String {
            switch self {
            case .unsupportedOS:
                return "Apple Intelligence text generation requires iOS 26, macOS 26, or visionOS 26."
            case .deviceNotEligible:
                return "This device does not support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in Settings to use the on-device model."
            case .modelNotReady:
                return "The Apple Intelligence model is still downloading. Try again once it is ready."
            case .unknown:
                return "The Apple Intelligence model is unavailable."
            }
        }
    }
}

// MARK: - Errors

public struct AppleIntelligenceErrorResponse: Codable, Error {
    public let message: String
    public init(message: String) { self.message = message }
}

public enum AppleIntelligenceError: Error, LocalizedError, Equatable {
    case unavailable(AppleIntelligence.UnavailableReason)
    case notAnHTTPProvider
    case missingPrompt
    case toolCallingUnsupported
    case structuredOutputUnsupported

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason.message
        case .notAnHTTPProvider: return "Apple Intelligence runs on-device and does not produce HTTP requests."
        case .missingPrompt: return "Apple Intelligence requests need a user message to respond to."
        case .toolCallingUnsupported: return "Tool calling is not yet supported for Apple Intelligence."
        case .structuredOutputUnsupported: return "Structured output is not yet supported for Apple Intelligence."
        }
    }
}

// MARK: - Request / Response

extension AppleIntelligence {
    /// Sampling strategy mirroring `GenerationOptions.SamplingMode`.
    public enum Sampling: Codable, Equatable, Sendable {
        case topK(Int, seed: UInt64? = nil)
        case topP(Double, seed: UInt64? = nil)
    }

    public struct ChatRequest: LangToolsChatRequest, LangToolsStreamableRequest {
        public typealias Response = ChatResponse
        public typealias LangTool = AppleIntelligence
        public typealias Message = AppleIntelligence.Message

        /// Not an HTTP endpoint; identifies the backing framework in logs.
        public static var endpoint: String { "foundation-models" }

        public let model: Model
        public var messages: [Message]
        public var stream: Bool?
        public var temperature: Double?
        public var maximumResponseTokens: Int?
        public var sampling: Sampling?

        public init(model: Model, messages: [any LangToolsMessage]) {
            self.init(model: model, messages: messages.map { Message($0) }, stream: nil)
        }

        public init(
            model: Model,
            messages: [Message],
            stream: Bool?,
            temperature: Double? = nil,
            maximumResponseTokens: Int? = nil,
            sampling: Sampling? = nil
        ) {
            self.model = model
            self.messages = messages
            self.stream = stream
            self.temperature = temperature
            self.maximumResponseTokens = maximumResponseTokens
            self.sampling = sampling
        }
    }

    public struct ChatResponse: LangToolsStreamableChatResponse {
        public typealias Message = AppleIntelligence.Message

        public var message: Message?
        public var delta: Delta?

        public init(message: Message? = nil, delta: Delta? = nil) {
            self.message = message
            self.delta = delta
        }

        public struct Delta: LangToolsMessageDelta {
            public var role: LangToolsRoleImpl?
            public var content: String?

            public init(role: LangToolsRoleImpl? = .assistant, content: String?) {
                self.role = role
                self.content = content
            }
        }

        public static var empty: ChatResponse { ChatResponse() }

        public func combining(with next: ChatResponse) -> ChatResponse {
            let text = (message?.content.text ?? delta?.content ?? "")
                + (next.message?.content.text ?? next.delta?.content ?? "")
            return ChatResponse(message: Message(role: .assistant, string: text))
        }
    }
}

// MARK: - Transcript planning (framework-independent, unit-testable)

extension AppleIntelligence {
    /// Provider-neutral plan for rebuilding a stateless message history as a
    /// Foundation Models transcript.
    struct TranscriptPlan: Equatable, Sendable {
        enum Turn: Equatable, Sendable {
            case user(String)
            case assistant(String)
        }

        /// Joined system messages, used as session instructions.
        var instructions: String?
        /// Prior turns replayed into the transcript before `prompt`.
        var history: [Turn]
        /// The final user message the model responds to.
        var prompt: String
    }

    static func transcriptPlan(for messages: [Message]) throws -> TranscriptPlan {
        let systemText = messages.filter { $0.role.isSystem }
            .map(\.content.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        var turns: [TranscriptPlan.Turn] = messages.compactMap { message in
            let text = message.content.text
            guard !text.isEmpty else { return nil }
            if message.role.isUser { return .user(text) }
            if message.role.isAssistant { return .assistant(text) }
            return nil
        }

        guard let lastUserIndex = turns.lastIndex(where: { if case .user = $0 { return true } else { return false } }),
              case .user(let prompt) = turns[lastUserIndex]
        else { throw AppleIntelligenceError.missingPrompt }
        // Anything after the final user turn (e.g. a dangling assistant draft) is dropped.
        turns.removeSubrange(lastUserIndex...)

        return TranscriptPlan(
            instructions: systemText.isEmpty ? nil : systemText,
            history: historyWindow(turns, prompt: prompt, instructions: systemText),
            prompt: prompt
        )
    }

    /// Chooses which prior turns to replay. The on-device model's context window
    /// (`AppleIntelligenceModel.contextWindowTokens`) is shared by instructions,
    /// history, prompt, and the generated response, so long chats overflow quickly
    /// and surface `GenerationError.exceededContextWindowSize`.
    ///
    /// Policy: keep the newest turns that fit an estimated token budget, after
    /// reserving room for the response. Instructions and the prompt are never
    /// trimmed; if they alone overflow, the framework's error is surfaced as-is.
    /// The kept window always starts on a user turn so no reply is orphaned from
    /// the question it answered.
    static func historyWindow(_ turns: [TranscriptPlan.Turn], prompt: String, instructions: String) -> [TranscriptPlan.Turn] {
        var budget = AppleIntelligenceModel.contextWindowTokens
            - reservedResponseTokens
            - estimatedTokens(instructions)
            - estimatedTokens(prompt)
        var keptCount = 0
        for turn in turns.reversed() {
            let cost: Int = switch turn {
            case .user(let text), .assistant(let text): estimatedTokens(text)
            }
            guard cost <= budget else { break }
            budget -= cost
            keptCount += 1
        }
        var kept = turns.suffix(keptCount)
        while let first = kept.first, case .assistant = first { kept.removeFirst() }
        return Array(kept)
    }

    /// Headroom left for the generated response when trimming history.
    static let reservedResponseTokens = 1_024

    /// Rough token estimate (~4 characters per token for English text). Rounded up
    /// and padded per turn for transcript framing so the estimate errs on trimming.
    static func estimatedTokens(_ text: String) -> Int {
        text.isEmpty ? 0 : (text.count + 3) / 4 + 4
    }
}
