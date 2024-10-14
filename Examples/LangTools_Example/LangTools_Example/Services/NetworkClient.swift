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
    private var langToolClient: (any LangTools)?
    private let userDefaults = UserDefaults.standard

    override init() {
        super.init()
        if let apiKey = keychainService.getApiKey(for: useAnthropic ? .anthropic : .openAI) {
            langToolClient = useAnthropic ? Anthropic(apiKey: apiKey) : OpenAI(apiKey: apiKey)
        }
    }

    func performChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = false, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) async throws -> Message {
        guard let langToolClient else { throw NetworkError.missingApiKey }
        if useAnthropic {
            let request = Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: messages.toAnthropicMessages(), stream: stream, tools: [], tool_choice: nil)
            let response = try await langToolClient.perform(request: request)
            guard let text = response.message?.content.string else { fatalError("the api should never return non text") }
            return Message(text: text, role: .assistant)
        } else if case .openAI(let model) = model {
            let request = OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice)
            let response = try await langToolClient.perform(request: request)
            guard case .string(let text) = response.choices[0].message?.content else { fatalError("the api should never return non text") }
            return Message(text: text, role: .assistant)
        }
        fatalError("how ya gonna use an anthropic model here? It ain't ready yet yo!")
    }

    func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = false, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<Message, Error> {
        guard let langToolClient else { throw NetworkError.missingApiKey }
        let uuid = UUID()
        var content = ""
        if useAnthropic { //, if case .anthropic(let model) = model {
            let request = Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: messages.toAnthropicMessages(), stream: true) //, tools: <#T##[Anthropic.Tool]?#>, tool_choice: <#T##Anthropic.MessageRequest.ToolChoice?#>)
            return AsyncThrowingStream { continuation in
                Task {
                    for try await response in langToolClient.stream(request: request) {
                        if case .string(let content) = response.message?.content {
                            continuation.yield(Message(uuid: uuid, text: content, role: .assistant))
                        } else if let chunk = response.stream?.delta?.text {
                            content = content + chunk
                            continuation.yield(Message(uuid: uuid, text: content, role: .assistant))
                        }
                    }
                    continuation.finish()
                }
            }
        } else if case .openAI(let model) = model  {
            let request = OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice)
            return AsyncThrowingStream { continuation in
                    Task {
                        for try await response in langToolClient.stream(request: request) {
                            if case .string(let content) = response.choices[0].message?.content {
                                continuation.yield(Message(uuid: uuid, text: content, role: .assistant))
                            } else if let chunk = response.choices[0].delta?.content {
                                content = content + chunk
                                continuation.yield(Message(uuid: uuid, text: content, role: .assistant))
                            }
                        }
                        continuation.finish()
                    }
                }
        }
        fatalError("this should never happen!")
    }

    func updateApiKey(_ apiKey: String) throws {
        guard !apiKey.isEmpty else { throw NetworkError.emptyApiKey }
        keychainService.saveApiKey(apiKey: apiKey, for: useAnthropic ? .anthropic : .openAI)
        langToolClient = useAnthropic ? Anthropic(apiKey: apiKey) : OpenAI(apiKey: apiKey)
    }
}

extension NetworkClient {
    enum NetworkError: Error {
        case missingApiKey
        case emptyApiKey
    }
}

