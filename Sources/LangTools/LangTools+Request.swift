//
//  LangToolsChatRequest.swift
//  LangTools
//
//  Created by Reid Chatham on 10/14/24.
//

import Foundation


public protocol LangToolsRequest: Encodable {
    associatedtype Response: Decodable
    associatedtype LangTool: LangTools
    static var path: String { get }
}

public extension LangToolsRequest {
    var path: String { Self.path }
}

// MARK: - LangToolsChatRequest
public protocol LangToolsChatRequest: LangToolsRequest where Response: LangToolsChatResponse, Response.Message == Message {
    associatedtype Message: LangToolsMessage
    var messages: [Message] { get set }
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

public protocol LangToolsStreamableChatResponse: LangToolsChatResponse, LangToolsStreamableResponse where Delta: LangToolsMessageDelta {}

extension LangToolsRequest {
    public var stream: Bool {
        get { return (self as? (any LangToolsStreamableRequest))?.stream ?? false }
    }

    func updating(stream: Bool) -> Self {
        if var streamReq = (self as? (any LangToolsStreamableRequest)) {
            streamReq.stream = stream
            return (streamReq as! Self)
        }
        return self
    }
}

// MARK: - LangToolsCompletableRequest
public protocol LangToolsCompletableRequest: LangToolsRequest {
    func completion(response: Response) throws -> Self?
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
            guard choose(from: response.choices) < n ?? 1 else { throw LangToolsRequestError.multipleChoiceIndexOutOfBounds }
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
    init(tool_selection_id: String, result: String)
}

public protocol LangToolsToolMessageDelta: Codable {
    associatedtype Role: LangToolsRole
    associatedtype ToolSelection: LangToolsToolSelection
    var role: Role? { get }
    var tool_selection: [ToolSelection]? { get }
}

public extension LangToolsToolCallingRequest where Self: LangToolsCompletableRequest {
    func completion<Response: LangToolsToolCallingResponse>(response: Response) throws -> Self? {
        guard let tool_selections = response.tool_selection, !tool_selections.isEmpty else { return nil }
        var tool_results: [Message.ToolResult] = []
        for tool_selection in tool_selections {
            guard let tool = tools?.first(where: { $0.name == tool_selection.name }) else { continue }
            guard let args = tool_selection.arguments.isEmpty ? [:] : tool_selection.arguments.dictionary
                else { throw LangToolsRequestError.failedToDecodeFunctionArguments }
            guard tool.tool_schema.required?.filter({ !args.keys.contains($0) }).isEmpty ?? true
                else { throw LangToolsRequestError.missingRequiredFunctionArguments }
            guard let str = tool.callback?(args) else { continue }
            tool_results.append(Message.ToolResult(tool_selection_id: tool_selection.id!, result: str))
        }
        guard !tool_results.isEmpty else { return nil }
        var results: [Message] = []
        if let message = response.message as! Self.Response.Message? {
            results.append(message)
        }
        results.append(contentsOf: Message.messages(for: tool_results))
        return updating(messages: messages + results)
    }
}

public enum LangToolsRequestError: Error {
    case failedToDecodeFunctionArguments
    case missingRequiredFunctionArguments
    case multipleChoiceIndexOutOfBounds
}

public protocol LangToolsTTSRequest: LangToolsRequest where Response == Data {}
