import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LangTools

final class LangToolchainTests: XCTestCase {
    func testPrepareDelegatesToFirstRegisteredProvider() throws {
        var toolchain = LangToolchain()
        toolchain.register(FirstTestProvider(marker: "first"))
        toolchain.register(SecondTestProvider(marker: "second"))

        let request = try toolchain.prepare(request: TestRequest())

        XCTAssertEqual(request.url, URL(string: "https://first.example.com/chat"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test-Provider"), "first")
    }

    func testDictionaryInitializerUsesSortedKeysForSelectionOrder() throws {
        let toolchain = LangToolchain(langTools: [
            "z-provider": FirstTestProvider(marker: "z"),
            "a-provider": SecondTestProvider(marker: "a"),
        ])

        let request = try toolchain.prepare(request: TestRequest())

        XCTAssertEqual(request.url?.host, "a.example.com")
    }

    func testRegistrationReplacementPreservesSlotAndTypeLookup() throws {
        var toolchain = LangToolchain()
        toolchain.register(FirstTestProvider(marker: "original"))
        toolchain.register(SecondTestProvider(marker: "second"))
        toolchain.register(FirstTestProvider(marker: "replacement"))

        XCTAssertEqual(toolchain.langTool(FirstTestProvider.self)?.marker, "replacement")
        XCTAssertEqual(toolchain.langTool(SecondTestProvider.self)?.marker, "second")

        let request = try toolchain.prepare(request: TestRequest())
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test-Provider"), "replacement")
    }

    func testPerformUsesRegistrationOrder() async throws {
        var toolchain = LangToolchain()
        toolchain.register(FirstTestProvider(marker: "first"))
        toolchain.register(SecondTestProvider(marker: "second"))

        let response = try await toolchain.perform(request: TestRequest())

        XCTAssertEqual(response.provider, "first")
    }

    func testTypedStreamUsesRegistrationOrder() async throws {
        var toolchain = LangToolchain()
        toolchain.register(SecondTestProvider(marker: "second"))
        toolchain.register(FirstTestProvider(marker: "first"))

        let stream: AsyncThrowingStream<TestResponse, Error> = toolchain.stream(request: TestRequest())
        var responses: [TestResponse] = []
        for try await response in stream {
            responses.append(response)
        }

        XCTAssertEqual(responses.map(\.provider), ["second"])
    }

    func testTypeErasedStreamUsesRegistrationOrder() async throws {
        var toolchain = LangToolchain()
        toolchain.register(FirstTestProvider(marker: "first"))
        toolchain.register(SecondTestProvider(marker: "second"))

        let stream: AsyncThrowingStream<any LangToolsStreamableResponse, Error> = try toolchain.stream(
            request: TestRequest()
        )
        var providers: [String] = []
        for try await response in stream {
            providers.append((response as? TestResponse)?.provider ?? "unexpected")
        }

        XCTAssertEqual(providers, ["first"])
    }

    func testNoHandlerErrorsAcrossOperations() async {
        let toolchain = LangToolchain()

        XCTAssertThrowsError(try toolchain.prepare(request: TestRequest())) {
            XCTAssertEqual($0 as? LangToolchainError, .toolchainCannotHandleRequest)
        }

        XCTAssertThrowsError(try {
            let stream: AsyncThrowingStream<any LangToolsStreamableResponse, Error> = try toolchain.stream(
                request: TestRequest()
            )
            return stream
        }()) {
            XCTAssertEqual($0 as? LangToolchainError, .toolchainCannotHandleRequest)
        }

        do {
            _ = try await toolchain.perform(request: TestRequest())
            XCTFail("Expected perform to reject an unhandled request")
        } catch {
            XCTAssertEqual(error as? LangToolchainError, .toolchainCannotHandleRequest)
        }

        do {
            let stream: AsyncThrowingStream<TestResponse, Error> = toolchain.stream(request: TestRequest())
            for try await _ in stream {}
            XCTFail("Expected stream to reject an unhandled request")
        } catch {
            XCTAssertEqual(error as? LangToolchainError, .toolchainCannotHandleRequest)
        }
    }
}

private struct TestRequest: LangToolsStreamableRequest {
    typealias LangTool = FirstTestProvider
    typealias Response = TestResponse

    static let endpoint = "chat"
    var stream: Bool?

    init(stream: Bool? = true) {
        self.stream = stream
    }
}

private struct TestResponse: Codable, LangToolsStreamableResponse {
    let provider: String
    var delta: String? { provider }

    static var empty: TestResponse { TestResponse(provider: "") }

    func combining(with next: TestResponse) -> TestResponse {
        next
    }
}

private enum TestModel: String {
    case test
}

private struct TestErrorResponse: Codable, Error {}

private protocol TestProvider: LangTools where Model == TestModel, ErrorResponse == TestErrorResponse {
    var marker: String { get }
    var host: String { get }
}

private extension TestProvider {
    static var requestValidators: [(any LangToolsRequest) -> Bool] {
        [{ $0 is TestRequest }]
    }

    var session: URLSession { .shared }

    static func chatRequest(
        model: any RawRepresentable,
        messages: [any LangToolsMessage],
        tools: [any LangToolsTool]?,
        responseSchema: JSONSchema?,
        toolEventHandler: @escaping (LangToolsToolEvent) -> Void
    ) throws -> any LangToolsChatRequest {
        throw LangToolsError.invalidArgument("Test provider does not support chat requests")
    }

    func prepare(request: some LangToolsRequest) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(host)/chat")!)
        request.setValue(marker, forHTTPHeaderField: "X-Test-Provider")
        return request
    }

    func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        guard let response = TestResponse(provider: marker) as? Request.Response else {
            throw LangToolsError.invalidArgument("Unexpected test response type")
        }
        return response
    }

    func stream<Request: LangToolsStreamableRequest>(
        request: Request
    ) -> AsyncThrowingStream<Request.Response, Error> {
        AsyncThrowingStream { continuation in
            guard let response = TestResponse(provider: marker) as? Request.Response else {
                continuation.finish(throwing: LangToolsError.invalidArgument("Unexpected test response type"))
                return
            }
            continuation.yield(response)
            continuation.finish()
        }
    }
}

private struct FirstTestProvider: TestProvider {
    let marker: String
    let host = "first.example.com"
}

private struct SecondTestProvider: TestProvider {
    let marker: String
    let host = "a.example.com"
}
