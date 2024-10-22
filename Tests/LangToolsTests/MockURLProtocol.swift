//
//  MockURLProtocol.swift
//  OpenAI-SwiftTests
//
//  Created by Reid Chatham on 12/30/23.
//

import Foundation
@testable import LangTools

class MockURLProtocol: URLProtocol {
    typealias MockNetworkHandler = (URLRequest) throws -> (
        result: Result<Data, Error>, statusCode: Int?
    )
    public static var mockNetworkHandlers: [String: MockNetworkHandler] = [:]

    override class func canInit(with request: URLRequest) -> Bool { mockNetworkHandlers[request.endpoint] != nil }
    override class func canInit(with task: URLSessionTask) -> Bool { mockNetworkHandlers[task.endpoint] != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = try! MockURLProtocol.mockNetworkHandlers.removeValue(forKey: request.endpoint)!(request)

        if let statusCode = response.statusCode {
            let httpURLResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            self.client?.urlProtocol(
                 self,
                 didReceive: httpURLResponse,
                 cacheStoragePolicy: .notAllowed
            )
        }

        switch response.result {
        case let .success(data):
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)

        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

}

extension URL {
    var endpoint: String { pathComponents[2...].joined(separator: "/") }
}

extension URLRequest {
    var endpoint: String { url!.endpoint }
}

extension URLSessionTask {
    var endpoint: String { currentRequest!.endpoint }
}

struct MockRequest: LangToolsRequest, LangToolsStreamableRequest, LangToolsCompletableRequest, Encodable {
    static var url: URL { URL(filePath: "test") }
    static var path: String { url.endpoint }
    typealias Response = MockResponse
    var stream: Bool?
    var messages: [MockMessage] = []
    init(stream: Bool? = nil) { self.stream = stream }
    func completion(response: MockResponse) throws -> MockRequest? { return nil }
}

struct MockResponse: Codable, LangToolsStreamableResponse {
    var status: String
    func combining(with next: MockResponse) -> MockResponse { MockResponse(status: status + next.status) }
    static var empty: MockResponse { MockResponse(status: "") }
    static var success: MockResponse { MockResponse(status: "success") }
}

struct MockMessage: Codable, LangToolsMessage {
    var role: MockRole
    var content: MockContent
    var tool_selection: [MockToolSelection]?
    init(tool_results: [MockToolResult]) {
        role = .user
        content = .init()
    }
}

enum MockRole: String, LangToolsRole {
    case user, assistant
}

struct MockContent: Codable, LangToolsContent {
    var string: String?
    var array: [MockContentType]?
}

struct MockContentType: Codable, LangToolsContentType {
    var type: String
}

struct MockToolSelection: Codable, LangToolsToolSelection {
    var id: String?
    var name: String?
    var arguments: String
}

struct MockToolResult: Codable, LangToolsToolSelectionResult {
    var tool_selection_id: String
    var result: String
    init(tool_selection_id: String, result: String) {
        self.tool_selection_id = tool_selection_id
        self.result = result
    }
}
