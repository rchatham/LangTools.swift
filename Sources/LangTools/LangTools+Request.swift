//
//  LangToolsChatRequest.swift
//  LangTools
//
//  Created by Reid Chatham on 10/14/24.
//

import Foundation


public protocol LangToolsRequest: Encodable {
    associatedtype Response: Decodable
    static var url: URL { get }
}

public protocol LangToolsChatRequest: LangToolsRequest where Response: LangToolsChatResponse, Response.Message == Message {
    associatedtype Message: LangToolsMessage
    var messages: [Message] { get set }
}

extension LangToolsRequest {
    public var stream: Bool {
        get { return (self as? (any LangToolsStreamableChatRequest))?.stream ?? false }
    }

    func updating(stream: Bool) -> Self {
        if var streamReq = (self as? (any LangToolsStreamableChatRequest)) {
            streamReq.stream = stream
            return (streamReq as! Self)
        }
        return self
    }
}

extension LangToolsChatRequest {
    public func updating(messages: [Message]) -> Self {
        var req = self
        req.messages = messages
        return req
    }
}

public protocol LangToolsChatResponse: Decodable {
    associatedtype Message: LangToolsMessage
    var message: Message? { get }
}

public protocol LangToolsStreamableChatRequest: LangToolsChatRequest where Response: LangToolsStreamableChatResponse {
    var stream: Bool? { get set }
}

public protocol LangToolsStreamableChatResponse: LangToolsChatResponse {
    associatedtype Delta: LangToolsMessageDelta
    var delta: Delta? { get }
    static var empty: Self { get }
    func combining(with: Self) -> Self
}

public protocol LangToolsCompletableChatRequest: LangToolsChatRequest {
    func completion(response: Response) throws -> Self?
}

public protocol LangToolsMultipleChoiceChatRequest: LangToolsChatRequest where Response: LangToolsMultipleChoiceChatResponse, Response.Choice == Self.Choice {
    associatedtype Choice: LangToolsMultipleChoiceChoice
    var n: Int? { get }
//    func pick(from choices: [Choice]) -> Int // Implement your own caching for this value
}

public extension LangToolsMultipleChoiceChatRequest where Self: LangToolsCompletableChatRequest {
//    func pick(from choices: [Choice]) -> Int { return 0 }
}

public protocol LangToolsMultipleChoiceChatResponse: LangToolsChatResponse {
    associatedtype Choice: LangToolsMultipleChoiceChoice
    var choices: [Choice] { get set }
//    var pick: (([Choice]) -> Int)? { get set }
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

public protocol LangToolsMessageDelta: Codable {
    associatedtype Role: LangToolsRole
    var role: Role? { get }
    var content: String? { get }
}

public protocol LangToolsToolMessageDelta: Codable {
    associatedtype Role: LangToolsRole
    associatedtype ToolSelection: LangToolsToolSelection
    var role: Role? { get }
    var tool_selection: [ToolSelection]? { get }
}

//public protocol LangToolsFinishReason: Codable {
//
//}

public protocol LangToolsToolCallingChatRequest: LangToolsChatRequest, Codable where Response: LangToolsToolCallingChatResponse, Message: LangToolsToolMessage {
    associatedtype Tool: LangToolsTool
    var tools: [Tool]? { get }
}

public protocol LangToolsToolCallingChatResponse: LangToolsChatResponse {
    associatedtype ToolSelection: LangToolsToolSelection
}

public extension LangToolsChatRequest where Self: LangToolsToolCallingChatRequest, Self: LangToolsCompletableChatRequest {
    func completion(response: Response) throws -> Self? {
        guard let tool_selections = response.message?.tool_selection else { return nil }
        var tool_results: [Message.ToolResult] = []
        for tool_selection in tool_selections {
            guard let tool = tools?.first(where: { $0.name == tool_selection.name }) else { continue }
            guard let args = tool_selection.arguments.isEmpty ? [:] : tool_selection.arguments.dictionary
                else { throw LangToolsChatRequestError.failedToDecodeFunctionArguments }
            guard tool.tool_schema.required?.filter({ !args.keys.contains($0) }).isEmpty ?? true
                else { throw LangToolsChatRequestError.missingRequiredFunctionArguments }
            guard let str = tool.callback?(args) else { continue }
            tool_results.append(Message.ToolResult(tool_selection_id: tool_selection.id!, result: str))
        }
        guard !tool_results.isEmpty else { return nil }
        var results: [Message] = []
        if let message = response.message {
            results.append(message)
        }
        results.append(contentsOf: Message.messages(for: tool_results))
        return updating(messages: messages + results)
    }
}

public enum LangToolsChatRequestError: Error {
    case failedToDecodeFunctionArguments
    case missingRequiredFunctionArguments
}

public protocol LangToolsTTSRequest: LangToolsRequest where Response == Data {}
