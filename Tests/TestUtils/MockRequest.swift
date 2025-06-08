//
//  MockRequest.swift
//  LangTools
//
//  Created by Reid Chatham on 11/3/24.
//

import Foundation
import LangTools


struct MockLangTool: LangTools {
    associatedtype Model = MockModel

    static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest {
        guard let model = model as? Model else { throw LangToolsError.invalidArgument("Unsupported model \(model)") }
        MockRequest(model: model, messages: messages)
    }

    typealias ErrorResponse = MockErrorResponse
    static var requestValidators: [(any LangToolsRequest) -> Bool] = [ { $0 is MockRequest } ]
    var session: URLSession
    func prepare(request: some LangToolsRequest) throws -> URLRequest {
        return URLRequest(url: URL(string: "http://localhost:8080/v1/")!)
    }
}

enum MockModel: String, RawRepresentable {
    case mockModel

    var rawValue: String { "mock-model" }
    init?(rawValue: String) {
        self = .mockModel
    }
}

struct MockRequest: LangToolsChatRequest, LangToolsStreamableRequest, Encodable {
    init(model: MockLangTool.Model, messages: [any LangToolsMessage]) {

    }

    typealias LangTool = MockLangTool
    typealias ToolResult = MockToolResult

    static var url: URL { URL(filePath: "test") }
    static var endpoint: String { url.endpoint }
    typealias Response = MockResponse
    var stream: Bool?
    var messages: [MockMessage] = []
    init(stream: Bool? = nil) { self.stream = stream }
}

struct MockResponse: Codable, LangToolsChatResponse, LangToolsStreamableResponse {
    typealias Delta = MockDelta
    typealias Message = MockMessage

    var status: String
    var message: MockMessage?
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
        content = .init(string: "")
        self.tool_selection = tool_selection
    }

    init(role: Role, content: Content) {
        self.role = role
        self.content = content
    }

    static func messages(for tool_results: [MockToolResult]) -> [MockMessage] {
        return [MockMessage(role: .assistant, content: .init([MockContentType(type: "tool", tool_results: tool_results)]))]
    }
}

struct MockDelta: LangToolsMessageDelta {
    var role: MockRole?
    var content: String?
}

enum MockRole: String, LangToolsRole {
    case user, assistant

    var isAssistant: Bool { self == .assistant }
    var isUser: Bool { self == .user }
    var isSystem: Bool { false }
    var isTool: Bool { false }

    init(_ role: any LangToolsRole) {
        if role.isUser { self = .user }
        else { self = .assistant }
    }
}

struct MockContent: Codable, LangToolsContent {
    init(_ content: any LangToolsContent) {}
    init(string: String) {}
    init(_ array: [MockContentType]) {}

    var string: String?
    var array: [MockContentType]?
}

struct MockContentType: Codable, LangToolsContentType {
    init(_ contentType: any LangToolsContentType) throws {
        type = contentType.type
        tool_results = nil
    }

    init(type: String, tool_results: [MockToolResult]) {
        self.type = type
        self.tool_results = tool_results
    }

    var type: String
    var tool_results: [MockToolResult]?
}

struct MockToolSelection: Codable, LangToolsToolSelection {
    var id: String?
    var name: String?
    var arguments: String
}

struct MockToolResult: Codable, LangToolsToolSelectionResult {
    public let tool_selection_id: String
    public let result: String
    public var is_error: Bool

    public init(tool_selection_id: String, result: String, is_error: Bool = false) {
        self.tool_selection_id = tool_selection_id
        self.result = result
        self.is_error = is_error
    }
    enum CodingKeys: CodingKey { case tool_selection_id, result, is_error }
}

struct MockErrorResponse: Codable, Error {

}
