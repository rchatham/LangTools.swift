import Agents
import Foundation
import LangTools
import OpenAI
import XCTest
@testable import Chat
@testable import ChatHistory

enum ScriptedError: Error, Equatable { case scripted, unexpected, saveFailed }

/// A network client that answers each request from a script. `.held`
/// replies stay open until the test yields chunks and finishes them.
final class ScriptedChatClient: NetworkClientProtocol {
    enum Reply {
        case text(String)
        /// Yields `partial` (when given), then fails.
        case failure(partial: String?)
        case held
        /// Reports a tool call, then fails before the tool completes.
        case toolCallThenFailure(name: String)
    }

    var replies: [Reply]
    private(set) var requests: [[Message]] = []
    private var held: [AsyncThrowingStream<String, Error>.Continuation] = []

    init(_ replies: [Reply] = []) { self.replies = replies }

    static var shared: NetworkClientProtocol { fatalError("No shared client in tests") }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        guard !replies.isEmpty else { XCTFail("Unscripted request"); throw ScriptedError.unexpected }
        requests.append(messages)
        let reply = replies.removeFirst()
        return AsyncThrowingStream { continuation in
            switch reply {
            case .text(let text):
                continuation.yield(text)
                continuation.finish()
            case .failure(let partial):
                if let partial { continuation.yield(partial) }
                continuation.finish(throwing: ScriptedError.scripted)
            case .held:
                held.append(continuation)
            case .toolCallThenFailure(let name):
                toolEventHandler(.toolCalled(OpenAI.Message.ToolCall(index: 0, id: "call-1", type: .function, function: .init(name: name, arguments: "{}"))))
                continuation.finish(throwing: ScriptedError.scripted)
            }
        }
    }

    func yieldHeld(_ chunk: String, index: Int = 0) { held[index].yield(chunk) }
    func finishHeld(index: Int = 0) { held[index].finish() }

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message { throw ScriptedError.unexpected }
    func playAudio(for text: String) async throws { throw ScriptedError.unexpected }
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw ScriptedError.unexpected }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws { throw ScriptedError.unexpected }
    func removeApiKey(for llm: APIService) throws { throw ScriptedError.unexpected }
    func connectAccount(_ provider: AccountLoginProvider) async throws { throw ScriptedError.unexpected }
    func disconnectAccount(_ provider: AccountLoginProvider) async throws { throw ScriptedError.unexpected }
}

@MainActor
enum TestHooks {
    /// Hooks with fixed settings and no tool registry, so tests never read
    /// app preferences.
    static func make(client: ScriptedChatClient, removesFailedPrompt: Bool = true) -> ChatSessionHooks {
        var hooks = ChatSessionHooks(makeMessageService: { context in
            MessageService(
                networkClient: client,
                agents: nil,
                tools: nil,
                dependencies: .init(
                    selectedModel: { .openAI(.gpt4o_mini) },
                    conversationSettings: {
                        DefaultChatSettingsResolver.merge(
                            ChatConversationSettings(systemPrompt: "test prompt"),
                            overrides: context.record?.settings ?? .none
                        )
                    },
                    keepsToolCallsInHistory: { true },
                    maxToolIterations: { nil },
                    enabledTools: { nil },
                    toolConfigurations: { [] }
                )
            )
        })
        hooks.removesFailedPromptWithoutOutput = removesFailedPrompt
        return hooks
    }
}

extension ChatPersistenceTiming {
    /// Long enough that only explicit or terminal flushes happen in a test.
    static let manual = ChatPersistenceTiming(debounce: 3600, maximumLatency: 3600, initialRetryDelay: 3600)
    /// Short delays for tests that exercise automatic flushing.
    static let fast = ChatPersistenceTiming(debounce: 0.01, maximumLatency: 0.05, initialRetryDelay: 0.01)
}

/// Polls the main actor until `condition` holds or the timeout passes.
@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

func text(_ value: String, _ role: Role, at seconds: TimeInterval) -> Message {
    Message(role: role, contentType: .string(value), createdAt: Date(timeIntervalSinceReferenceDate: seconds))
}

func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ChatHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "ChatHistory.store")
}

/// Fails the test if `condition` does not become true within the timeout.
@MainActor
func assertEventually(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let satisfied = await waitUntil(timeout: timeout, condition)
    XCTAssertTrue(satisfied, "Condition not met within \(timeout)s", file: file, line: line)
}
