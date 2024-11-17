//
//  NetworkClient.swift
//
//  Created by Reid Chatham on 1/20/23.
//

import Foundation
import LangTools
import OpenAI
import Anthropic

//typealias Model = OpenAI.Model
typealias Role = OpenAI.Message.Role

let useAnthropic = true

class NetworkClient: NSObject, URLSessionWebSocketDelegate {
    static let shared = NetworkClient()

    private let keychainService = KeychainService()
    private var userDefaults: UserDefaults { .standard }

    private var langToolchain = LangToolchain()

    override init() {
        super.init()
        if let apiKey = keychainService.getApiKey(for: .anthropic) {
            langToolchain.register(Anthropic(apiKey: apiKey))
        }
        if let apiKey = keychainService.getApiKey(for: .openAI) {
            langToolchain.register(OpenAI(apiKey: apiKey))
        }
    }

    func performChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = false, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) async throws -> Message {
        let response = try await performLangToolsChatRequest(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)
        guard let text = response?.message?.content.string else { fatalError("the api should never return non text") }
        return Message(text: text, role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = false, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<Message, Error> {
        let stream = try streamLangToolsChatRequest(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)
        return AsyncThrowingStream { continuation in
            Task {
                let uuid = UUID()
                var content = ""
                for try await response in stream {
                    if let content = response.message?.content.string {
                        continuation.yield(Message(uuid: uuid, text: content, role: .assistant))
                    } else if let chunk = (response as? any LangToolsStreamableChatResponse)?.delta?.content {
                        content = content + chunk
                        continuation.yield(Message(uuid: uuid, text: content, role: .assistant))
                    }
                }
                continuation.finish()
            }
        }
    }

    private func performLangToolsChatRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = false, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) async throws -> (any LangToolsChatResponse)? {
        let request: any LangToolsChatRequest = if !useAnthropic, case .openAI(let model) = model { OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice) } else { Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: messages.toAnthropicMessages(), stream: stream, tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice()) }
        return try await langToolchain.perform(request: request)
    }

    private func streamLangToolsChatRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = false, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<any LangToolsChatResponse, Error> {
        let request: any LangToolsStreamableChatRequest = if !useAnthropic, case .openAI(let model) = model { OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice) } else { Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: messages.toAnthropicMessages(), stream: stream, tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice()) }
        return try langToolchain.stream(request: request) // I'm shocked this works, an `any LangToolsStreamableChatRequest` is being passed to a function that expects `some LangToolsStreamableChatRequest`.
    }

    func updateApiKey(_ apiKey: String) throws {
        guard !apiKey.isEmpty else { throw NetworkError.emptyApiKey }
        keychainService.saveApiKey(apiKey: apiKey, for: useAnthropic ? .anthropic : .openAI)
        let langTools: any LangTools = useAnthropic ? Anthropic(apiKey: apiKey) : OpenAI(apiKey: apiKey)
        langToolchain.register(langTools)
    }
}

extension NetworkClient {
    enum NetworkError: Error {
        case missingApiKey
        case emptyApiKey
        case incompatibleRequest
    }
}
