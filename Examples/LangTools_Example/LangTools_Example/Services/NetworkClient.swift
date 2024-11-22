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
        let uuid = UUID()
        var content: String?
        return try streamLangToolsChatRequest(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice).compactMapAsyncThrowingStream { response in
            content ?= (response.message?.content.string ?? response.delta?.content.map { (content ?? "") + $0 })
            return content.flatMap { Message(uuid: uuid, text: $0, role: .assistant) }
        }
    }

    func playAudio(for text: String) async {
        let audioReq = OpenAI.AudioSpeechRequest(model: .tts_1_hd, input: text, voice: .alloy, responseFormat: .mp3, speed: 1.0)
        let audioResponse: Data = try! await langToolchain.perform(request: audioReq)
        do { try AudioPlayer.shared.play(data: audioResponse) }
        catch { print(error.localizedDescription) }
    }

    private func performLangToolsChatRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = false, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) async throws -> (any LangToolsChatResponse)? {
        return try await langToolchain.perform(request: request(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice))
    }

    private func streamLangToolsChatRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = false, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<any LangToolsStreamableChatResponse, Error> {
        return try langToolchain.stream(request: request(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)) // I'm shocked this works, an `any LangToolsStreamableChatRequest` is being passed to a function that expects `some LangToolsStreamableChatRequest`.
    }

    func request(messages: [Message], model: Model, stream: Bool, tools: [OpenAI.Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) -> any LangToolsStreamableChatRequest {
        return if !useAnthropic, case .openAI(let model) = model { OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice) } else { Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: messages.toAnthropicMessages(), stream: stream, tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice()) }
    }

    func updateApiKey(_ apiKey: String, for apiKeychainService: APIKeychainService) throws {
        guard !apiKey.isEmpty else { throw NetworkError.emptyApiKey }
        keychainService.saveApiKey(apiKey: apiKey, for: apiKeychainService)
        let langTools: any LangTools = apiKeychainService == .anthropic ? Anthropic(apiKey: apiKey) : OpenAI(apiKey: apiKey)
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
