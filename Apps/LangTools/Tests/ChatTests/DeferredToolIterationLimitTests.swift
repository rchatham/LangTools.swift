import Agents
import ChatUI
import Foundation
import LangTools
import OpenAI
import XCTest
@testable import Chat

@MainActor
final class DeferredToolIterationLimitTests: XCTestCase {
    func testStoredIterationCapDoesNotManufactureFailuresOrOrphanSuccesses() async throws {
        let preferences = DeferredIterationPreferenceSnapshot()
        let oldCap = ToolSettings.shared.maxToolIterations
        let oldHistory = ToolSettings.shared.keepsToolCallsInHistory
        defer {
            ToolSettings.shared.maxToolIterations = oldCap
            ToolSettings.shared.keepsToolCallsInHistory = oldHistory
            preferences.restore()
        }
        ToolSettings.shared.maxToolIterations = 1
        ToolSettings.shared.keepsToolCallsInHistory = true
        UserDefaults.model = .openAI(.gpt4o)

        let counter = DeferredIterationCounter()
        let client = DeferredIterationClient(counter: counter)
        defer { client.session.invalidateAndCancel() }
        let service = MessageService(networkClient: client)
        var updatedCalls: [ChatToolCall] = []
        service.messageUpdatedCallback = { message in
            updatedCalls.append(contentsOf: message.toolCalls)
        }
        let operation = service.sendOperation(message: "Run five synthetic callbacks", stream: true)
        try await operation.waitUntilEstablished()
        try await operation.waitForCompletion()

        let callbackCount = await counter.count
        XCTAssertEqual(callbackCount, 5, "Real provider tool callbacks run beyond the stored cap")
        let calls = service.messages.flatMap(\.toolCalls)
        XCTAssertEqual(calls.count, 5, "One invocation record per callback, no orphan duplicates")
        XCTAssertEqual(Set(calls.map(\.id)).count, 5, "UI invocation identities remain distinct")
        XCTAssertTrue(calls.allSatisfy { $0.status == .success })
        XCTAssertTrue(calls.allSatisfy { $0.name == "synthetic_side_effect" })
        XCTAssertEqual(calls.map(\.result), (1...5).map { "side-effect-\($0)" })
        XCTAssertFalse(updatedCalls.contains { $0.status == .failure }, "No transient falsely failed cards either")
        XCTAssertEqual(ToolSettings.shared.maxToolIterations, 1, "Persisted compatibility value is retained")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "maxToolIterations"), 1)
    }

}

/// Restore only changed keys from a complete snapshot, including missing keys.
/// This avoids persisting untouched global-domain defaults into the app domain.
private struct DeferredIterationPreferenceSnapshot {
    private let original = UserDefaults.standard.dictionaryRepresentation()
    func restore() {
        let defaults = UserDefaults.standard
        let current = defaults.dictionaryRepresentation()
        for key in Set(original.keys).union(current.keys) {
            let before = original[key] as? NSObject
            let after = current[key] as? NSObject
            guard before != after else { continue }
            if let value = original[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
}

private actor DeferredIterationCounter {
    private(set) var count = 0
    func record() -> String {
        count += 1
        return "side-effect-\(count)"
    }
}

/// Exercise LangTools' actual callback/completion loop behind MessageService's
/// public client seam. URLProtocol serves synthetic responses; no live model.
private final class DeferredIterationClient: NetworkClientProtocol {
    static let shared: any NetworkClientProtocol = DeferredIterationClient(counter: DeferredIterationCounter())
    let session: URLSession
    private let provider: OpenAI
    private let counter: DeferredIterationCounter

    init(counter: DeferredIterationCounter) {
        self.counter = counter
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeferredIterationURLProtocol.self]
        session = URLSession(configuration: configuration)
        provider = OpenAI(baseURL: URL(string: "https://mr21-synthetic.invalid/v1/")!, apiKey: "synthetic-not-a-credential", session: session)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        let tool = OpenAI.Tool(name: "synthetic_side_effect", description: "Deterministic test callback", tool_schema: .init(properties: [:])) { [counter] _, _ in
            await counter.record()
        }
        let request = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: messages.toOpenAIMessages(), tools: [tool], toolEventHandler: toolEventHandler)
        return AsyncThrowingStream { continuation in
            let task = Task { [provider] in
                do {
                    let response = try await provider.perform(request: request)
                    continuation.yield(response.choices.first?.message?.content.string ?? "")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message { throw NetworkClient.NetworkError.incompatibleRequest }
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw NetworkClient.NetworkError.incompatibleRequest }
    func playAudio(for text: String) async throws {}
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}

private final class DeferredIterationURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mr21-synthetic.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data: Data
            if let body = request.httpBody { data = body }
            else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw try XCTUnwrap(stream.streamError) }
                    if count == 0 { break }
                    bytes.append(buffer, count: count)
                }
                data = bytes
            }
            let requestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try XCTUnwrap(requestObject["messages"] as? [[String: Any]])
            let completed = messages.contains { ($0["role"] as? String) == "tool" }
            let message: [String: Any]
            if completed {
                message = ["role": "assistant", "content": "Five callbacks completed."]
            } else {
                message = ["role": "assistant", "content": NSNull(), "tool_calls": (1...5).map { index in
                    ["id": "synthetic-\(index)", "type": "function", "function": ["name": "synthetic_side_effect", "arguments": "{}"]] as [String: Any]
                }]
            }
            let responseBody: [String: Any] = [
                "id": "synthetic-completion", "object": "chat.completion", "created": 1, "model": "gpt-4o",
                "choices": [["index": 0, "message": message, "finish_reason": completed ? "stop" : "tool_calls"]]
            ]
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: responseBody))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
