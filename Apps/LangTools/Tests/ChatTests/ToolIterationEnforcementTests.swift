import Agents
import ChatUI
import Foundation
import LangTools
import OpenAI
import ToolKit
import XCTest
@testable import Chat

/// Enforces the configured Max Iterations budget at the MessageService seam:
/// over-budget callbacks never execute, and every requested call still gets an
/// invocation record — excess calls surface as inline failures the model can
/// see and respond to (no orphans, no alerts).
@MainActor
final class ToolIterationEnforcementTests: XCTestCase {
    func testBudgetStopsExcessCallbacksAndSurfacesInlineFailures() async throws {
        let preferences = ToolSettingsAmbientSnapshot()
        let oldCap = ToolSettings.shared.maxToolIterations
        let oldHistory = ToolSettings.shared.keepsToolCallsInHistory
        let oldToolsEnabled = ToolManager.shared.toolsEnabled
        let oldSyntheticEnabled = ToolManager.shared["synthetic_side_effect"]
        defer {
            ToolSettings.shared.maxToolIterations = oldCap
            ToolSettings.shared.keepsToolCallsInHistory = oldHistory
            ToolManager.shared.toolsEnabled = oldToolsEnabled
            ToolManager.shared["synthetic_side_effect"] = oldSyntheticEnabled
            preferences.restore()
        }
        ToolSettings.shared.maxToolIterations = 1
        ToolSettings.shared.keepsToolCallsInHistory = true
        UserDefaults.model = .openAI(.gpt4o)
        ToolManager.shared.toolsEnabled = true

        let counter = ToolIterationCounter()
        // `filteredTools(for:)` intersects service tools with ToolManager's
        // enabled registrations, so the synthetic tool must be registered for
        // `budgetedTools(_:)` to wrap — and therefore budget — its callback.
        ToolManager.shared.register(
            ToolConfiguration(
                id: "synthetic_side_effect",
                displayName: "Synthetic Side Effect",
                description: "Deterministic test callback",
                iconName: "wrench",
                callback: { _ in await counter.record() },
                toolSchema: OpenAI.Tool.FunctionSchema.Parameters()
            )
        )

        let client = ToolIterationEnforcementClient()
        defer { client.session.invalidateAndCancel() }
        let service = MessageService(networkClient: client)
        let operation = service.sendOperation(message: "Run five synthetic callbacks", stream: true)
        try await operation.waitUntilEstablished()
        try await operation.waitForCompletion()

        let callbackCount = await counter.count
        XCTAssertEqual(callbackCount, 1, "The budget stops callback execution after the first iteration")

        let calls = service.messages.flatMap(\.toolCalls)
        XCTAssertEqual(calls.count, 5, "One invocation record per requested call")
        XCTAssertEqual(Set(calls.map(\.id)).count, 5, "UI invocation identities remain distinct")
        XCTAssertTrue(calls.allSatisfy { $0.status != .pending }, "Every card settles — no orphans")
        XCTAssertTrue(calls.allSatisfy { $0.name == "synthetic_side_effect" })
        let successes = calls.filter { $0.status == .success }
        XCTAssertEqual(successes.count, 1, "Only the budgeted iteration succeeds")
        XCTAssertEqual(successes.first?.result, "side-effect-1")
        let failures = calls.filter { $0.status == .failure }
        XCTAssertEqual(failures.count, 4, "Excess iterations surface as inline failures")
        XCTAssertTrue(
            failures.allSatisfy { $0.result == "Tool iteration limit reached." },
            "Inline failures explain the budget: \(calls.map(\.result))"
        )
        XCTAssertEqual(ToolSettings.shared.maxToolIterations, 1, "Persisted compatibility value is retained")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "maxToolIterations"), 1)
    }

}

private actor ToolIterationCounter {
    private(set) var count = 0
    func record() -> String {
        count += 1
        return "side-effect-\(count)"
    }
}

/// Exercise LangTools' actual callback/completion loop behind MessageService's
/// public client seam. The budgeted tools MessageService passes in are routed
/// through the same provider conversion seam the real client uses
/// (`tools?.convertTools()`), so the iteration budget applies to the stub's
/// callbacks exactly as it does in production. URLProtocol serves synthetic
/// responses; no live model.
private final class ToolIterationEnforcementClient: NetworkClientProtocol {
    static let shared: any NetworkClientProtocol = ToolIterationEnforcementClient()
    let session: URLSession
    private let provider: OpenAI

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ToolIterationEnforcementURLProtocol.self]
        session = URLSession(configuration: configuration)
        provider = OpenAI(baseURL: URL(string: "https://mr21-synthetic.invalid/v1/")!, apiKey: "synthetic-not-a-credential", session: session)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        let request = OpenAI.ChatCompletionRequest(
            model: .gpt4o,
            messages: messages.toOpenAIMessages(),
            tools: tools?.convertTools(),
            toolEventHandler: toolEventHandler
        )
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

private final class ToolIterationEnforcementURLProtocol: URLProtocol {
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
