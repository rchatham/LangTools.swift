import Foundation
import OpenAI
import XCTest
@testable import LangTools
@testable import ExampleAgents

final class ResearchAgentStartupTests: XCTestCase {
    func testConstructionInstructionsAndSchemasDoNotUseStorage() throws {
        let store = CountingResearchStore()
        store.failReads = true
        let agent = ResearchAgent(credentialStore: store)
        XCTAssertEqual(agent.name, "researchAgent")
        XCTAssertFalse(agent.instructions.isEmpty)
        XCTAssertEqual(agent.delegateAgents.map(\.name), ["webScrapingAgent"])
        let tool = try XCTUnwrap(agent.tools?.first)
        XCTAssertEqual(tool.name, "google_search")
        XCTAssertEqual(Set(tool.tool_schema.properties.keys), ["query", "num_results"])
        XCTAssertEqual(tool.tool_schema.required, ["query"])
        XCTAssertEqual(store.readCount, 0)
        XCTAssertTrue(store.savedKeys.isEmpty)
    }

    func testExplicitKeyNeverReadsOrWritesStorage() async throws {
        let store = CountingResearchStore()
        store.failReads = true
        let agent = ResearchAgent(serperApiKey: "dummy-explicit-key", credentialStore: store, session: session())
        let output = try await search(agent)
        XCTAssertTrue(output?.contains("Fixture result") == true)
        XCTAssertEqual(ResearchURLProtocol.lastKey, "dummy-explicit-key")
        XCTAssertEqual(store.readCount, 0)
        XCTAssertTrue(store.savedKeys.isEmpty)
        let tool = try XCTUnwrap(agent.tools?.first as? SerperTool)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(tool), as: UTF8.self).contains("dummy-explicit-key"))
        XCTAssertFalse(agent.instructions.contains("dummy-explicit-key"))
    }

    func testSavedKeyIsResolvedOnlyAtInvocationWithoutSynchronization() async throws {
        let store = CountingResearchStore()
        store.key = "dummy-saved-key"
        let agent = ResearchAgent(credentialStore: store, session: session())
        _ = agent.instructions
        XCTAssertEqual(store.readCount, 0)
        _ = try await search(agent)
        XCTAssertEqual(store.readCount, 1)
        XCTAssertEqual(ResearchURLProtocol.lastKey, "dummy-saved-key")
        XCTAssertTrue(store.savedKeys.isEmpty)
        store.key = "dummy-changed-key"
        _ = try await search(agent)
        XCTAssertEqual(ResearchURLProtocol.lastKey, "dummy-changed-key")
        XCTAssertTrue(store.savedKeys.isEmpty)
    }

    func testMissingKeyAndStorageFailureAreSanitized() async throws {
        let store = CountingResearchStore()
        let agent = ResearchAgent(credentialStore: store, session: session())
        do {
            _ = try await search(agent)
            XCTFail("Missing credentials must fail before transport")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("settings"))
            XCTAssertFalse(error.localizedDescription.contains("dummy-private-error"))
        }
        store.failReads = true
        do {
            _ = try await search(agent)
            XCTFail("Storage failure must fail before transport")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("dummy-private-error"))
        }
        XCTAssertEqual(ResearchURLProtocol.requestCount, 0)
        XCTAssertTrue(store.savedKeys.isEmpty)
    }

    func testInvalidArgumentsDoNotResolveCredentials() async throws {
        let store = CountingResearchStore()
        let agent = ResearchAgent(credentialStore: store, session: session())
        let tool = try XCTUnwrap(agent.tools?.first)
        do {
            _ = try await tool.callback?(requestInfo(), [:])
            XCTFail("Missing query must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("query"))
        }
        XCTAssertEqual(store.readCount, 0)
        XCTAssertEqual(ResearchURLProtocol.requestCount, 0)
    }

    func testExplicitUpdatePersistsAndReplacesToolOnlyAfterSuccess() async throws {
        let store = CountingResearchStore()
        var agent = ResearchAgent(serperApiKey: "dummy-original-key", credentialStore: store, session: session())
        try agent.updateApiKey("dummy-updated-key")
        XCTAssertEqual(store.savedKeys, ["dummy-updated-key"])
        _ = try await search(agent)
        XCTAssertEqual(ResearchURLProtocol.lastKey, "dummy-updated-key")
        store.failSaves = true
        XCTAssertThrowsError(try agent.updateApiKey("dummy-rejected-key")) { error in
            XCTAssertFalse(error.localizedDescription.contains("dummy-private-error"))
        }
        _ = try await search(agent)
        XCTAssertEqual(ResearchURLProtocol.lastKey, "dummy-updated-key")
        XCTAssertThrowsError(try agent.updateApiKey(""))
        XCTAssertEqual(store.readCount, 0)
    }

    func testTransportErrorsCannotReflectCredentials() async throws {
        let agent = ResearchAgent(serperApiKey: "dummy-explicit-key", credentialStore: CountingResearchStore(), session: session())
        ResearchURLProtocol.failTransport = true
        do {
            _ = try await search(agent)
            XCTFail("Transport failure must throw")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("dummy-explicit-key"))
            XCTAssertFalse(error.localizedDescription.contains("dummy-private-error"))
        }
    }

    func testCancelledInvocationDoesNotReadCredentialsOrUseTransport() async throws {
        let store = CountingResearchStore()
        let agent = ResearchAgent(credentialStore: store, session: session())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await search(agent)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled search must fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(store.readCount, 0)
        XCTAssertEqual(ResearchURLProtocol.requestCount, 0)
    }

    func testExistingExplicitSerperToolInitializerStillWorks() async throws {
        let tool = SerperTool(apiKey: "dummy-direct-tool-key", session: session())
        let result = try await tool.callback?(requestInfo(), ["query": .string("fixture")])
        XCTAssertTrue(result?.contains("Fixture result") == true)
        XCTAssertEqual(ResearchURLProtocol.lastKey, "dummy-direct-tool-key")
    }

    private func session() -> URLSession {
        ResearchURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResearchURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestInfo() -> LangToolsRequestInfo {
        .init(langTool: OpenAI(apiKey: "unused-dummy-key"), model: OpenAI.Model.gpt4o, messages: [])
    }

    private func search(_ agent: ResearchAgent) async throws -> String? {
        let tool = try XCTUnwrap(agent.tools?.first)
        return try await tool.callback?(requestInfo(), ["query": .string("fixture"), "num_results": .number(2)])
    }
}

private final class CountingResearchStore: ResearchCredentialStore {
    var key: String?
    var readCount = 0
    var savedKeys: [String] = []
    var failReads = false
    var failSaves = false

    func readApiKey() throws -> String? {
        readCount += 1
        if failReads { throw NSError(domain: "dummy-private-error", code: 1) }
        return key
    }

    func saveApiKey(_ apiKey: String) throws {
        if failSaves { throw NSError(domain: "dummy-private-error", code: 2) }
        savedKeys.append(apiKey)
        key = apiKey
    }
}

private final class ResearchURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var capturedKey: String?
    private static var requests = 0
    private static var shouldFailTransport = false
    static var failTransport: Bool {
        get { lock.withLock { shouldFailTransport } }
        set { lock.withLock { shouldFailTransport = newValue } }
    }
    static var lastKey: String? { lock.withLock { capturedKey } }
    static var requestCount: Int { lock.withLock { requests } }

    static func reset() {
        lock.withLock { capturedKey = nil; requests = 0; shouldFailTransport = false }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self.capturedKey = request.value(forHTTPHeaderField: "X-API-KEY")
            Self.requests += 1
        }
        if Self.failTransport {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "dummy-private-error-dummy-explicit-key", code: 1))
            return
        }
        let data = Data(#"{"searchParameters":{"q":"fixture","num":2},"organic":[{"title":"Fixture result","link":"https://example.invalid/fixture","snippet":"Synthetic","position":1}],"knowledgeGraph":null}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
