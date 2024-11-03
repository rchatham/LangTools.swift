import XCTest
@testable import LangTools
@testable import OpenAI

final class LangToolsTests: XCTestCase {

    var api: OpenAI!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = OpenAI(apiKey: "").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    func test() async throws {
        MockURLProtocol.mockNetworkHandlers[MockRequest.path] = { request in
            return (.success(try MockResponse.success.data()), 200)
        }
        let response = try await api.perform(request: MockRequest())
        XCTAssertEqual(response.status, "success")
    }

    func testStream() async throws {
        MockURLProtocol.mockNetworkHandlers[MockRequest.path] = { request in
            return (.success(try MockResponse.success.streamData()), 200)
        }
        var results: [MockResponse] = []
        for try await response in api.stream(request: MockRequest(stream: true)) {
            results.append(response)
        }
        let content = results.reduce("") { $0 + ($1.status) }
        XCTAssertEqual(content, "success")
    }
}
