//
//  NetworkClient.swift
//
//  Created by Reid Chatham on 1/20/23.
//

import Foundation
import LangTools
import OpenAI
import Anthropic
import AVFAudio

//typealias Model = OpenAI.Model
typealias Role = OpenAI.Message.Role

let useAnthropic = false

class NetworkClient: NSObject, URLSessionWebSocketDelegate {
    static let shared = NetworkClient()

    private let keychainService = KeychainService()
    private var userDefaults: UserDefaults { .standard }

    private var langToolchain = LangToolchain()

    override init() {
        super.init()
        if let apiKey = keychainService.getApiKey(for: .anthropic) { register(apiKey, for: .anthropic) }
        if let apiKey = keychainService.getApiKey(for: .openAI) { register(apiKey, for: .openAI) }
    }

    func performChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) async throws -> Message {
        let response = try await langToolchain.perform(request: request(messages: messages, model: model, tools: tools, toolChoice: toolChoice))
        guard let text = response.message?.content.string else { fatalError("the api should never return non text") }
        return Message(text: text, role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = true, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<Message, Error> {
        let uuid = UUID(); var content: String?
        return try langToolchain.stream(request: request(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)).compactMapAsyncThrowingStream { response in
            content ?= (response.delta?.content.map { (content ?? "") + $0 } ?? (response as? (any LangToolsChatResponse))?.message?.content.string)
            return content.flatMap { Message(uuid: uuid, text: $0, role: .assistant) }
        }
    }

    func playAudio(for text: String) async throws {
        let audioReq = OpenAI.AudioSpeechRequest(model: .tts_1_hd, input: text, voice: .alloy, responseFormat: .mp3, speed: 1.2)
        let audioResponse: Data = try await langToolchain.perform(request: audioReq)
        do { try AudioPlayer.shared.play(data: audioResponse) }
        catch { print(error.localizedDescription) }
    }

    func request(messages: [Message], model: Model, stream: Bool = false, tools: [OpenAI.Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) -> any LangToolsChatRequest & LangToolsStreamableRequest {
        if useAnthropic, case .anthropic(let model) = model {
            return Anthropic.MessageRequest(model: model, messages: messages.toAnthropicMessages(), stream: stream, tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice())
        } else if case .openAI(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), n: 3, stream: stream, tools: tools, tool_choice: toolChoice, choose: {_ in 2})
        } else {
            return Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: messages.toAnthropicMessages(), stream: stream, tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice())
        }
    }

    func updateApiKey(_ apiKey: String, for llm: LLMAPIService) throws {
        guard !apiKey.isEmpty else { throw NetworkError.emptyApiKey }
        keychainService.saveApiKey(apiKey: apiKey, for: llm)
        register(apiKey, for: llm)
    }

    func register(_ apiKey: String, for llm: LLMAPIService) {
        let langTools: any LangTools = llm == .anthropic ? Anthropic(apiKey: apiKey) : OpenAI(apiKey: apiKey)
        langToolchain.register(langTools)
    }
}

enum LLMAPIService: String {
    case openAI, anthropic
}

extension NetworkClient {
    enum NetworkError: Error {
        case missingApiKey
        case emptyApiKey
        case incompatibleRequest
    }
}
