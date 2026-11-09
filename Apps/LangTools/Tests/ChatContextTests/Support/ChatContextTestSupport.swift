import Agents
import ChatUI
import Foundation
import LangTools
import Ollama
import OpenAI
import XCTest
@testable import Chat
@testable import ChatContext

enum ContextTestError: Error, Equatable { case summarizerDown, saveFailed, unexpected }

/// A model without a published window, so tests set the window through
/// `CompactionPolicy.fallbackContextWindowTokens`.
let unknownWindowModel = Model.ollama(Ollama.Model(rawValue: "context-test:latest")!)

/// A policy whose input budget is easy to reason about: a 4,000-token
/// window with no reply reserve, compacting above 80% (3,200) down to 50%
/// (2,000), with room for a 200-token summary.
func testPolicy(
    window: Int = 4_000,
    isEnabled: Bool = true,
    minimumRecentTurns: Int = 1
) -> CompactionPolicy {
    CompactionPolicy(
        isEnabled: isEnabled,
        triggerPercent: 80,
        targetPercent: 50,
        minimumRecentTurns: minimumRecentTurns,
        summaryTokenLimit: 200,
        reservedResponseTokens: 0,
        fallbackContextWindowTokens: window
    )
}

/// Text that costs exactly `tokens` estimated tokens (ASCII, 4 bytes per token).
func filler(_ tokens: Int, _ tag: String = "") -> String {
    var text = tag.isEmpty ? "" : tag + " "
    while text.count < tokens * 4 { text += "word " }
    return String(text.prefix(tokens * 4))
}

/// A user prompt and its reply, each about `tokens` tokens.
func turn(_ index: Int, tokens: Int = 100) -> [Message] {
    let prompt = Message(text: filler(tokens, "q\(index)"), role: .user)
    let reply = Message(text: filler(tokens, "a\(index)"), role: .assistant)
    reply.responseToMessageID = prompt.uuid
    return [prompt, reply]
}

func conversation(turns count: Int, tokens: Int = 100, prompt: String = "current question") -> [Message] {
    (0..<count).flatMap { turn($0, tokens: tokens) } + [Message(text: prompt, role: .user)]
}

func requestContext(
    _ history: [Message],
    model: Model = unknownWindowModel,
    systemPrompt: String = "system",
    settings: ChatConversationSettings = .default,
    inFlight: Set<UUID> = [],
    tools: [Tool] = [],
    overflow: ContextOverflow? = nil
) -> ChatRequestContext {
    ChatRequestContext(
        systemPrompt: systemPrompt,
        history: history,
        model: model,
        settings: settings,
        inFlightMessageIDs: inFlight,
        tools: tools,
        contextOverflow: overflow
    )
}

/// A tool whose description costs about `descriptionTokens` tokens.
func contextTestTool(_ name: String = "lookup", descriptionTokens: Int = 10) -> Tool {
    Tool(
        name: name,
        description: filler(descriptionTokens, "Finds"),
        tool_schema: ToolSchema(
            properties: ["query": ToolSchemaProperty(type: "string", description: "What to find")],
            required: ["query"]
        )
    )
}

/// An error body as a provider sends it, decoded into no provider's type.
struct ProviderMessageError: Error, Codable, Equatable {
    let message: String
}

/// Anthropic's wording for a request over the window, inside the error
/// `LangTools` throws for an unsuccessful response.
func promptTooLong(_ requested: Int, _ maximum: Int) -> Error {
    LangToolsError.responseUnsuccessful(
        statusCode: 400,
        ProviderMessageError(message: "prompt is too long: \(requested) tokens > \(maximum) maximum")
    )
}

/// Records requests and answers with a fixed summary, optionally failing or
/// waiting for the test to release it.
@MainActor
final class RecordingSummarizer: ConversationSummarizer {
    var requests: [SummaryRequest] = []
    var error: Error?
    var reply: (SummaryRequest) -> String = { request in
        "summary of \(request.messages.count) messages" + (request.previousSummary.map { " after [\($0)]" } ?? "")
    }
    var gate: CheckedContinuation<Void, Never>?
    var holds = false

    func summarize(_ request: SummaryRequest) async throws -> ContextSummary {
        requests.append(request)
        if holds {
            await withCheckedContinuation { gate = $0 }
        }
        try Task.checkCancellation()
        if let error { throw error }
        return ContextSummary(text: reply(request), model: "test/summarizer")
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

/// A network client that records requests and replies from a script.
final class ContextScriptedClient: NetworkClientProtocol {
    var replies: [Result<String, Error>]
    private(set) var requests: [(messages: [Message], model: Model, tools: [Tool]?)] = []
    /// Fails the next successful reply after its text, as if the stream broke.
    var failAfterNextReply: Error?
    /// Reported to the next request's tool handler before its reply.
    var toolEventBeforeNextReply: LangToolsToolEvent?

    init(_ replies: [Result<String, Error>] = []) { self.replies = replies }

    static var shared: NetworkClientProtocol { fatalError("No shared client in tests") }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        guard !replies.isEmpty else { XCTFail("Unscripted request"); throw ContextTestError.unexpected }
        requests.append((messages, model, tools))
        let reply = replies.removeFirst()
        let trailingError = failAfterNextReply
        failAfterNextReply = nil
        if let event = toolEventBeforeNextReply {
            toolEventBeforeNextReply = nil
            toolEventHandler(event)
        }
        return AsyncThrowingStream { continuation in
            switch reply {
            case .success(let text):
                continuation.yield(text)
                if let trailingError {
                    continuation.finish(throwing: trailingError)
                } else {
                    continuation.finish()
                }
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message { throw ContextTestError.unexpected }
    func playAudio(for text: String) async throws { throw ContextTestError.unexpected }
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw ContextTestError.unexpected }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws { throw ContextTestError.unexpected }
    func removeApiKey(for llm: APIService) throws { throw ContextTestError.unexpected }
    func connectAccount(_ provider: AccountLoginProvider) async throws { throw ContextTestError.unexpected }
    func disconnectAccount(_ provider: AccountLoginProvider) async throws { throw ContextTestError.unexpected }
}
