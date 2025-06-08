//
//  LangToolsChatRequest.swift
//  LangTools
//
//  Created by Reid Chatham on 10/14/24.
//

import Foundation


// MARK: - LangToolsRequest
public protocol LangToolsRequest: Encodable {
    associatedtype Response: Decodable
    associatedtype LangTool: LangTools
    static var endpoint: String { get }
    static var httpMethod: HTTPMethod { get }
}

public extension LangToolsRequest {
    var endpoint: String { Self.endpoint }
    static var httpMethod: HTTPMethod { .post }
}

// MARK: - LangToolsChatRequest
public protocol LangToolsChatRequest: LangToolsRequest where Response: LangToolsChatResponse, Response.Message == Message {
    associatedtype Message: LangToolsMessage
    var model: LangTool.Model { get }
    var messages: [Message] { get set }

    init(model: LangTool.Model, messages: [any LangToolsMessage])
}

extension LangToolsChatRequest {
    func updating(messages: [Message]) -> Self {
        var req = self
        req.messages = messages
        return req
    }
}

public protocol LangToolsChatResponse: Decodable {
    associatedtype Message: LangToolsMessage
    var message: Message? { get }
}

// MARK: - LangToolsStreamableRequest
public protocol LangToolsStreamableRequest: LangToolsRequest where Response: LangToolsStreamableResponse {
    var stream: Bool? { get set }
}

public protocol LangToolsStreamableResponse: Decodable {
    associatedtype Delta
    var delta: Delta? { get }
    static var empty: Self { get }
    func combining(with: Self) -> Self
}

extension LangToolsStreamableResponse {
    public var content: (any LangToolsContent)? { (self as? any LangToolsStreamableChatResponse)?.delta?.content.map { LangToolsTextContent(text: $0) }  ?? (self as? any LangToolsChatResponse)?.message?.content }
}

public protocol LangToolsStreamableChatResponse: LangToolsChatResponse, LangToolsStreamableResponse where Delta: LangToolsMessageDelta {}

extension LangToolsRequest {
    public var stream: Bool { get { (self as? (any LangToolsStreamableRequest))?.stream ?? false } }

    func updating(stream: Bool) -> Self {
        if var streamReq = (self as? (any LangToolsStreamableRequest)) {
            streamReq.stream = stream
            return (streamReq as! Self)
        }
        return self
    }
}

// MARK: - LangToolsMultipleChoiceChatRequest
public protocol LangToolsMultipleChoiceChatRequest: LangToolsChatRequest where Response: LangToolsMultipleChoiceChatResponse {
    var n: Int? { get }
    func choose(from choices: [Response.Choice]) -> Int // Implement your own caching for this value
}

extension LangToolsMultipleChoiceChatRequest {
    func choose(from choices: [Response.Choice]) -> Int { return 0 }
}

extension LangToolsMultipleChoiceChatRequest {
    func update(response: Decodable) throws -> Decodable {
        if var response = response as? Response {
            let choice = choose(from: response.choices)
            guard choice < n ?? 1 else { throw LangToolsRequestError.multipleChoiceIndexOutOfBounds(choice) }
            response.choose = choose
            return response
        }
        return response
    }
}

extension LangToolsRequest {
    func update<Response: Decodable>(response: Response) throws -> Response {
        return try (self as? (any LangToolsMultipleChoiceChatRequest))?.update(response: response) as? Response ?? response
    }
}

public protocol LangToolsMultipleChoiceChatResponse: LangToolsChatResponse {
    associatedtype Choice: LangToolsMultipleChoiceChoice
    var choices: [Choice] { get set }
    var choose: (([Choice]) -> Int)? { get set }
}

public extension LangToolsMultipleChoiceChatResponse {
    var choice: Choice? { choices.first(where: { $0.index == choose?(choices) }) }
}

public extension LangToolsMultipleChoiceChatResponse where Self: LangToolsStreamableResponse {
    var delta: Choice.Delta? { choice?.delta }
    var message: Choice.Message? { choice?.message }
}

public protocol LangToolsMultipleChoiceChoice: Codable {
    associatedtype Delta: LangToolsMessageDelta
    associatedtype Message: LangToolsMessage
//    associatedtype FinishReason: LangToolsFinishReason
    var index: Int { get }
    var message: Message? { get }
    var delta: Delta? { get }
//    var finish_reason: FinishReason? { get }
}

//public protocol LangToolsFinishReason: Codable {
//
//}

// MARK: - LangToolsToolCallingRequest
public protocol LangToolsToolCallingRequest: LangToolsChatRequest, Codable where Response: LangToolsToolCallingResponse, Message: LangToolsToolMessage, Message == Response.Message {
    associatedtype Tool: LangToolsTool
    var tools: [Tool]? { get }
    var toolEventHandler: ((LangToolsToolEvent) -> Void)? { get }
}

public enum LangToolsToolEvent {
    case toolCalled(any LangToolsToolSelection)
    case toolCompleted((any LangToolsToolSelectionResult)?)
}

public protocol LangToolsToolCallingResponse: LangToolsChatResponse where Message: LangToolsToolMessage, ToolSelection == Message.ToolSelection {
    associatedtype ToolSelection: LangToolsToolSelection
}

extension LangToolsToolCallingResponse {
    var tool_selection: [ToolSelection]? {
        message?.tool_selection
    }
}

public protocol LangToolsToolSelection: Codable {
    var id: String? { get }
    var name: String? { get }
    var arguments: String { get }
}

public protocol LangToolsToolSelectionResult: Codable {
    var tool_selection_id: String { get }
    var result: String { get }
    var is_error: Bool { get }
    init(tool_selection_id: String, result: String)
    init(tool_selection_id: String, result: String, is_error: Bool)
}

extension LangToolsToolSelectionResult {
    public init(tool_selection_id: String, result: String) {
        self.init(tool_selection_id: tool_selection_id, result: result, is_error: false)
    }
}

public protocol LangToolsToolMessageDelta: Codable {
    associatedtype Role: LangToolsRole
    associatedtype ToolSelection: LangToolsToolSelection
    var role: Role? { get }
    var tool_selection: [ToolSelection]? { get }
}

public struct LangToolsRequestInfo {
    public var langTool: any LangTools
    public var model: any RawRepresentable
    public var messages: [any LangToolsMessage]
}

extension LangToolsToolCallingRequest {
    func completion<Response: LangToolsToolCallingResponse>(_ langTool: some LangTools, response: Response) async throws -> Self? {
        guard let tool_selections = response.tool_selection as? [Message.ToolSelection], !tool_selections.isEmpty else { return nil }
        var tool_results: [Message.ToolResult] = []
        for tool_selection in tool_selections {
            toolEventHandler?(.toolCalled(tool_selection))
            guard let tool = tools?.first(where: { $0.name == tool_selection.name }) else { continue }
            do {
                guard let args = tool_selection.arguments.isEmpty ? [:] : try? JSON(string: tool_selection.arguments).objectValue
                    else { throw LangToolsRequestError.failedToDecodeFunctionArguments(tool_selection.arguments) }
                let missing = tool.tool_schema.required?.filter({ !args.keys.contains($0) })
                guard missing?.isEmpty ?? true
                else { throw LangToolsRequestError.missingRequiredFunctionArguments(missing!.joined(separator: ",")) }
                let info = LangToolsRequestInfo(langTool: langTool, model: model, messages: messages)
                guard let str = try await tool.callback?(info, args) else { toolEventHandler?(.toolCompleted(nil)); continue }
                tool_results.append(Message.ToolResult(tool_selection_id: tool_selection.id!, result: str))
            } catch {
                tool_results.append(Message.ToolResult(tool_selection_id: tool_selection.id!, result: "\(error.localizedDescription)", is_error: true))
            }
            toolEventHandler?(.toolCompleted(tool_results.last))
        }
        guard !tool_results.isEmpty else { return nil }
        var results: [Message] = []
        if var message = response.message as! Self.Response.Message? {
            let toolSelectionsWithResult = tool_selections.filter({ tool_results.map{ $0.tool_selection_id }.contains($0.id) })
            results.append(Message(tool_selection: toolSelectionsWithResult))
        }
        results.append(contentsOf: Message.messages(for: tool_results))
        return updating(messages: messages + results)
    }
}

public enum LangToolsRequestError: Error {
    case failedToDecodeFunctionArguments(String)
    case missingRequiredFunctionArguments(String)
    case multipleChoiceIndexOutOfBounds(Int)

    var localizedDescription: String {
        switch self {
        case .failedToDecodeFunctionArguments(let str): return "Failed to decode function arguments: " + str
        case .missingRequiredFunctionArguments(let str): return "Missing required function arguments: " + str
        case .multipleChoiceIndexOutOfBounds(let int): return "Multiple choice index out of bounds: \(int)"
        }
    }
}

// MARK: - LangToolsTTSRequest
public protocol LangToolsTTSRequest: LangToolsRequest where Response == Data {}

public enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
}
