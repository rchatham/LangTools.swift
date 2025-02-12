//
//  NetworkClient.swift
//
//  Created by Reid Chatham on 1/20/23.
//

import Foundation
import LangTools
import OpenAI
import Anthropic
import XAI
import Gemini
import Ollama
import AVFAudio
import Agents

typealias Role = OpenAI.Message.Role

class NetworkClient: NSObject, URLSessionWebSocketDelegate {
    static let shared = NetworkClient()

    private let keychainService = KeychainService()
    private var userDefaults: UserDefaults { .standard }

    private var langToolchain = LangToolchain()

    override init() {
        super.init()
        LLMAPIService.allCases.forEach { llm in keychainService.getApiKey(for: llm).flatMap { register($0, for: llm) } }
    }

    func performChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) async throws -> Message {
        let response = try await langToolchain.perform(request: request(messages: messages, model: model, tools: tools, toolChoice: toolChoice))
        guard let text = response.content?.text else { fatalError("the api should never return non text") }
        return Message(text: text, role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = true, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<String, Error> {
        return try langToolchain.stream(request: request(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)).compactMapAsyncThrowingStream { $0.content?.text }
    }

    func playAudio(for text: String) async throws {
        let audioReq = OpenAI.AudioSpeechRequest(model: .tts_1_hd, input: text, voice: .alloy, responseFormat: .mp3, speed: 1.2)
        let audioResponse: Data = try await langToolchain.perform(request: audioReq)
        do { try AudioPlayer.shared.play(data: audioResponse) }
        catch { print(error.localizedDescription) }
    }

    func request(messages: [Message], model: Model, stream: Bool = false, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) -> any LangToolsChatRequest & LangToolsStreamableRequest {
        if case .anthropic(let model) = model {
            return Anthropic.MessageRequest(model: model, messages: messages.toAnthropicMessages(), stream: stream, system: messages.createAnthropicSystemMessage(), tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice())
        } else if case .openAI(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), /*n: 3,*/ stream: stream, tools: tools, tool_choice: toolChoice/*, choose: {_ in 2}*/)
        } else if case .xAI(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice)
        } else if case .gemini(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream/*, tools: tools, tool_choice: toolChoice*/)
        } else if case .ollama(let model) = model {
            return Ollama.ChatRequest(model: model, messages: messages.toOllamaMessages(), format: nil, options: nil, stream: stream, keep_alive: nil, tools: tools)
        } else {
            return Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: messages.toAnthropicMessages(), stream: stream, system: messages.createAnthropicSystemMessage(), tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice())
        }
    }

    func calendarAgent(model: Model = UserDefaults.model) -> any Agent {
        if case .anthropic(let model) = model {
            return CalendarAgent(langTool: langToolchain.langTool(Anthropic.self)!, model: model)
        } else if case .openAI(let model) = model {
            return CalendarAgent(langTool: langToolchain.langTool(OpenAI.self)!, model: model)
        } else if case .xAI(let model) = model {
            return CalendarAgent(langTool: langToolchain.langTool(XAI.self)!, model: model)
        } else if case .gemini(let model) = model {
            return CalendarAgent(langTool: langToolchain.langTool(Gemini.self)!, model: model)
        } else if case .ollama(let model) = model {
            return CalendarAgent(langTool: langToolchain.langTool(Ollama.self)!, model: model)
        } else {
            return CalendarAgent(langTool: langToolchain.langTool(Anthropic.self)!, model: .claude35Sonnet_latest)
        }
    }

    func updateApiKey(_ apiKey: String, for llm: LLMAPIService) throws {
        guard !apiKey.isEmpty else { throw NetworkError.emptyApiKey }
        keychainService.saveApiKey(apiKey: apiKey, for: llm)
        register(apiKey, for: llm)
    }

    func register(_ apiKey: String, for llm: LLMAPIService) {
        langToolchain.register(langTool(for: llm, with: apiKey))
    }

    func langTool(for llm: LLMAPIService, with apiKey: String) -> any LangTools {
        let baseURL: URL? = nil //URL(string: "http://localhost:8080/v1/")
        switch llm {
        case .anthropic: return if let baseURL { Anthropic(baseURL: baseURL, apiKey: apiKey) } else { Anthropic(apiKey: apiKey) }
        case .openAI: return if let baseURL { OpenAI(baseURL: baseURL, apiKey: apiKey) } else { OpenAI(apiKey: apiKey) }
        case .xAI: return if let baseURL { XAI(baseURL: baseURL, apiKey: apiKey) } else { XAI(apiKey: apiKey) }
        case .gemini: return if let baseURL { Gemini(baseURL: baseURL, apiKey: apiKey) } else { Gemini(apiKey: apiKey) }
        case .ollama: return Ollama()
        }
    }
}

enum LLMAPIService: String, CaseIterable {
    case openAI, anthropic, xAI, gemini, ollama
}

extension NetworkClient {
    enum NetworkError: Error {
        case missingApiKey
        case emptyApiKey
        case incompatibleRequest
    }
}

extension String {
    func trimingTrailingNewlines() -> String {
        return trimingTrailingCharacters(using: .newlines)
    }

    func trimingTrailingCharacters(using characterSet: CharacterSet = .whitespacesAndNewlines) -> String {
        guard let index = lastIndex(where: { !CharacterSet(charactersIn: String($0)).isSubset(of: characterSet) }) else {
            return self
        }

        return String(self[...index])
    }
}
