//
//  LangToolsRequest.swift
//  LangTools
//
//  Created by Reid Chatham on 10/14/24.
//

import Foundation


public protocol LangToolsRequest: Encodable {
    associatedtype Response: Decodable
    associatedtype Message: LangToolsMessage
    static var url: URL { get }
    var messages: [Message] { get set }
}

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

    public func updating(messages: [Message]) -> Self {
        var req = self
        req.messages = messages
        return req
    }
}

public protocol LangToolsStreamableRequest: LangToolsRequest where Response: LangToolsStreamableResponse {
    var stream: Bool? { get set }
}

public protocol LangToolsStreamableResponse: Decodable {
    static var empty: Self { get }
    func combining(with: Self) -> Self
}

public protocol LangToolsCompletableRequest: LangToolsRequest { //where Message.ToolResult == ToolResult {
//    associatedtype ToolResult: LangToolsToolSelectionResult
    func completion(response: Response) throws -> Self?
}

public protocol LangToolsMultipleChoiceRequest: LangToolsRequest where Response: LangToolsMultipleChoiceResponse, Response.Choice == Self.Choice {
    associatedtype Choice: LangToolsMultipleChoiceChoice
    var n: Int? { get }
    func pick(from choices: [Choice]) -> Int // Implement your own caching for this value
}

public extension LangToolsMultipleChoiceRequest where Self: LangToolsCompletableRequest {
//    func completion(response: Response) throws -> Self? {
//        var response = response
//        response.choices = [response.choices[pick(from: response.choices)]]
//        return try completion(response: response)
//    }
    func pick(from choices: [Choice]) -> Int { return 0 }
}

public protocol LangToolsMultipleChoiceResponse: Codable {
    associatedtype Choice: LangToolsMultipleChoiceChoice
    var choices: [Choice] { get set }
}

public protocol LangToolsMultipleChoiceChoice: Codable {
    associatedtype Delta: LangToolsMessageDelta
    associatedtype Message: LangToolsMessage
    associatedtype FinishReason: LangToolsFinishReason
    var index: Int { get }
    var message: Message? { get }
    var delta: Delta? { get }
    var finish_reason: FinishReason? { get }
}

public protocol LangToolsToolSelection: Codable {
    var id: String? { get }
    var name: String? { get }
    var arguments: String { get }
}

public protocol LangToolsToolSelectionResult: Codable {
//    associatedtype Content: LangToolsContent
    var tool_selection_id: String { get }
    var result: String { get }
    init(tool_selection_id: String, result: String)
}

public protocol LangToolsMessageDelta: Codable {
    associatedtype Role: LangToolsRole
    associatedtype ToolSelection: LangToolsToolSelection
    var role: Role? { get }
    var content: String? { get }
    var tool_selection: [ToolSelection]? { get }
}

public protocol LangToolsFinishReason: Codable {

}

public protocol LangToolsToolCallingRequest: LangToolsRequest, Codable where Response: LangToolsToolCallingResponse {
    associatedtype Tool: LangToolsTool
    var tools: [Tool]? { get }
}

public protocol LangToolsToolCallingResponse: Codable {
    associatedtype ToolSelection: LangToolsToolSelection
    var tool_selection: [ToolSelection]? { get }
}

public extension LangToolsToolCallingRequest where Self: LangToolsMultipleChoiceRequest, Choice.Message == Message, Response.ToolSelection == Message.ToolSelection, Choice.Delta.ToolSelection == Message.ToolSelection {
    func toolSelection(for response: Response) -> [Response.ToolSelection]? {
        let choice = response.choices[pick(from: response.choices)]
        return choice.message?.tool_selection ?? choice.delta?.tool_selection
    }
}

public extension LangToolsRequest where Self: LangToolsToolCallingRequest, Self: LangToolsCompletableRequest {
    func completion(response: Response) throws -> Self? {
        guard let tool_selections = response.tool_selection else { return nil }
        var tool_results: [Message.ToolResult] = []
        for tool_selection in tool_selections {
            guard let tool = tools?.first(where: { $0.name == tool_selection.name }) else { continue }
            guard let args = tool_selection.arguments.dictionary else { throw LangToolsRequestError.failedToDecodeFunctionArguments }
            guard tool.tool_schema.required?.filter({ !args.keys.contains($0) }).isEmpty ?? true else { throw LangToolsRequestError.missingRequiredFunctionArguments }
            guard let str = tool.callback?(args) else { continue }
            tool_results.append(Message.ToolResult.init(tool_selection_id: tool_selection.id!, result: str))
        }
        guard !tool_results.isEmpty else { return nil }
        return updating(messages: messages + [Message(tool_results: tool_results)])
    }
}


public enum LangToolsRequestError: Error {
    case failedToDecodeFunctionArguments
    case missingRequiredFunctionArguments
}
