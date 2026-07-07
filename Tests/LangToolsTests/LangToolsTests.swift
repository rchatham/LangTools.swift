import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TestUtils
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
        MockURLProtocol.mockNetworkHandlers[MockRequest.endpoint] = { request in
            return (.success(try MockResponse.success.data()), 200)
        }
        let response = try await api.perform(request: MockRequest())
        XCTAssertEqual(response.status, "success")
    }

    func testStream() async throws {
        MockURLProtocol.mockNetworkHandlers[MockRequest.endpoint] = { request in
            return (.success(try MockResponse.success.streamData()), 200)
        }
        var results: [MockResponse] = []
        for try await response in api.stream(request: MockRequest(stream: true)) {
            results.append(response)
        }
        let content = results.reduce("") { $0 + ($1.status) }
        XCTAssertEqual(content, "success")
    }

    // MARK: - LangToolsError Tests

    func testLangToolsErrorInvalidData() {
        let error = LangToolsError.invalidData
        XCTAssertNotNil(error)
    }

    func testLangToolsErrorInvalidContentType() {
        let error = LangToolsError.invalidContentType
        XCTAssertNotNil(error)
    }

    func testLangToolsErrorInvalidArgument() {
        let error = LangToolsError.invalidArgument("test argument")
        if case .invalidArgument(let message) = error {
            XCTAssertEqual(message, "test argument")
        } else {
            XCTFail("Expected invalidArgument error")
        }
    }

    func testLangToolsErrorResponseUnsuccessful() {
        let error = LangToolsError.responseUnsuccessful(statusCode: 404, nil)
        if case .responseUnsuccessful(let statusCode, _) = error {
            XCTAssertEqual(statusCode, 404)
        } else {
            XCTFail("Expected responseUnsuccessful error")
        }
    }

    // MARK: - LangToolsRole Tests

    func testLangToolsRoleImpl() {
        let systemRole = LangToolsRoleImpl.system
        XCTAssertTrue(systemRole.isSystem)
        XCTAssertFalse(systemRole.isUser)
        XCTAssertFalse(systemRole.isAssistant)
        XCTAssertFalse(systemRole.isTool)

        let userRole = LangToolsRoleImpl.user
        XCTAssertTrue(userRole.isUser)
        XCTAssertFalse(userRole.isSystem)

        let assistantRole = LangToolsRoleImpl.assistant
        XCTAssertTrue(assistantRole.isAssistant)
        XCTAssertFalse(assistantRole.isUser)

        let toolRole = LangToolsRoleImpl.tool
        XCTAssertTrue(toolRole.isTool)
        XCTAssertFalse(toolRole.isAssistant)
    }

    // MARK: - LangToolsContent Tests

    func testLangToolsTextContent() {
        let content = LangToolsTextContent(text: "Hello, World!")
        XCTAssertEqual(content.text, "Hello, World!")
        XCTAssertEqual(content.string, "Hello, World!")
        XCTAssertEqual(content.type, "text")
    }

    func testLangToolsTextContentExpressibleByStringLiteral() {
        let content: LangToolsTextContent = "Test message"
        XCTAssertEqual(content.text, "Test message")
    }

    func testLangToolsTextContentFromContent() {
        let original = LangToolsTextContent(text: "Original text")
        let copy = LangToolsTextContent(original)
        XCTAssertEqual(copy.text, "Original text")
    }

    // MARK: - LangToolsMessage Tests

    func testLangToolsMessageImpl() {
        let message = LangToolsMessageImpl<LangToolsTextContent>(role: .user, string: "Hello")
        XCTAssertTrue(message.role.isUser)
        XCTAssertEqual(message.content.text, "Hello")
    }

    // MARK: - HTTP Error Response Tests

    func testErrorResponse() async throws {
        MockURLProtocol.mockNetworkHandlers[MockRequest.endpoint] = { request in
            return (.success(Data()), 500)
        }

        do {
            _ = try await api.perform(request: MockRequest())
            XCTFail("Expected error to be thrown")
        } catch let error as LangToolsError {
            if case .responseUnsuccessful(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 500)
            } else {
                XCTFail("Expected responseUnsuccessful error")
            }
        }
    }
}
