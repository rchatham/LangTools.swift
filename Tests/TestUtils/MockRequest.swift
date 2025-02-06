//
//  MockRequest.swift
//  LangTools
//
//  Created by Reid Chatham on 11/3/24.
//

import Foundation
import LangTools


struct MockLangTool: LangTools {
    typealias ErrorResponse = MockErrorResponse
    static var requestValidators: [(any LangToolsRequest) -> Bool] = [ { $0 is MockRequest } ]
    var session: URLSession
    func prepare(request: some LangToolsRequest) throws -> URLRequest {
        return URLRequest(url: URL(string: "http://localhost:8080/v1/")!)
    }
}

struct MockRequest: LangToolsRequest, LangToolsStreamableRequest, LangToolsCompletableRequest, Encodable {
    typealias LangTool = MockLangTool
    typealias ToolResult = MockToolResult

    static var url: URL { URL(filePath: "test") }
    static var endpoint: String { url.endpoint }
    typealias Response = MockResponse
    var stream: Bool?
    var messages: [MockMessage] = []
    init(stream: Bool? = nil) { self.stream = stream }
    func completion(response: MockResponse) throws -> MockRequest? { return nil }
}

struct MockResponse: Codable, LangToolsStreamableResponse {
    typealias Delta = MockDelta
    typealias Message = MockMessage

    var status: String
    var delta: MockDelta?

    func combining(with next: MockResponse) -> MockResponse { MockResponse(status: status + next.status) }
    static var empty: MockResponse { MockResponse(status: "") }
    static var success: MockResponse { MockResponse(status: "success") }
}

struct MockMessage: Codable, LangToolsMessage {
    typealias Role = MockRole
    typealias Content = MockContent
    typealias ToolSelection = MockToolSelection
    typealias ToolResult = MockToolResult

    var role: MockRole
    var content: MockContent
    var tool_selection: [MockToolSelection]?
    init(tool_selection: [MockToolSelection]) {
        role = .assistant
        content = Content()
        self.tool_selection = tool_selection
    }

    init(role: Role, content: Content) {
        self.role = role
        self.content = content
    }

    static func messages(for tool_results: [MockToolResult]) -> [MockMessage] {
        return [MockMessage(role: .assistant, content: .init(array: [MockContentType(type: "tool", tool_results: tool_results)]))]
    }
}

struct MockDelta: LangToolsMessageDelta {
    var role: MockRole?
    var content: String?
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
    var tool_results: [MockToolResult]?
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

struct MockErrorResponse: Codable, Error {

}
