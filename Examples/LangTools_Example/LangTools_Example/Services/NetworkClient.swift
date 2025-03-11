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
        APIService.llms.forEach { llm in keychainService.getApiKey(for: llm).flatMap { registerLangTool($0, for: llm) } }
        keychainService.saveApiKey(apiKey: "", for: .serper)

        // For Ollama, we don't need an API key
        registerLangTool("", for: .ollama)

        // Initialize Ollama service to start populating available models
        _ = OllamaService.shared
    }

    func performChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) async throws -> Message {
        let response = try await langToolchain.perform(request: request(messages: messages, model: model, tools: tools, toolChoice: toolChoice))
        guard let text = response.content?.text else { fatalError("the api should never return non text") }
        return Message(text: text, role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = true, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<String, Error> {
        return try langToolchain.stream(request: request(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)).compactMapAsyncThrowingStream { $0.content?.text }
    }

    func playAudio(for text: String) async throws {
        let audioReq = OpenAI.AudioSpeechRequest(model: .tts_1_hd, input: text, voice: .alloy, responseFormat: .mp3, speed: 1.2)
        let audioResponse: Data = try await langToolchain.perform(request: audioReq)
        do { try AudioPlayer.shared.play(data: audioResponse) }
        catch { print(error.localizedDescription) }
    }

    func request(messages: [Message], model: Model, stream: Bool = false, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) -> any LangToolsChatRequest & LangToolsStreamableRequest {
        if case .anthropic(let model) = model {
            return Anthropic.MessageRequest(model: model, messages: messages.toAnthropicMessages(), stream: stream, system: messages.createAnthropicSystemMessage(), tools: tools?.convertTools(), tool_choice: toolChoice?.toAnthropicToolChoice())
        } else if case .openAI(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), /*n: 3,*/ stream: stream, tools: tools?.convertTools(), tool_choice: toolChoice/*, choose: {_ in 2}*/)
        } else if case .xAI(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools?.convertTools(), tool_choice: toolChoice)
        } else if case .gemini(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream/*, tools: tools, tool_choice: toolChoice*/)
        } else if case .ollama(let model) = model {
            return Ollama.ChatRequest(model: model, messages: messages.toOllamaMessages(), format: nil, options: nil, stream: stream, keep_alive: nil/*, tools: tools?.convertTools()*/)
        } else {
            return Anthropic.MessageRequest(model: .claude35Sonnet_20240620, messages: messages.toAnthropicMessages(), stream: stream, system: messages.createAnthropicSystemMessage(), tools: tools?.convertTools(), tool_choice: toolChoice?.toAnthropicToolChoice())
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

    func reminderAgent(model: Model = UserDefaults.model) -> any Agent {
        if case .anthropic(let model) = model {
            return ReminderAgent(langTool: langToolchain.langTool(Anthropic.self)!, model: model)
        } else if case .openAI(let model) = model {
            return ReminderAgent(langTool: langToolchain.langTool(OpenAI.self)!, model: model)
        } else if case .xAI(let model) = model {
            return ReminderAgent(langTool: langToolchain.langTool(XAI.self)!, model: model)
        } else if case .gemini(let model) = model {
            return ReminderAgent(langTool: langToolchain.langTool(Gemini.self)!, model: model)
        } else if case .ollama(let model) = model {
            return ReminderAgent(langTool: langToolchain.langTool(Ollama.self)!, model: model)
        } else {
            return ReminderAgent(langTool: langToolchain.langTool(Anthropic.self)!, model: .claude35Sonnet_latest)
        }
    }

    func researchAgent(model: Model = UserDefaults.model) -> (any Agent)? {
        guard let serperApiKey = keychainService.getApiKey(for: .serper) else { return nil }
        switch model {
        case .anthropic(let model):
            return ResearchAgent(langTool: langToolchain.langTool(Anthropic.self)!, model: model, serperApiKey: serperApiKey)
        case .openAI(let model):
            return ResearchAgent(langTool: langToolchain.langTool(OpenAI.self)!, model: model, serperApiKey: serperApiKey)
        case .xAI(let model):
            return ResearchAgent(langTool: langToolchain.langTool(XAI.self)!, model: model, serperApiKey: serperApiKey)
        case .gemini(let model):
            return ResearchAgent(langTool: langToolchain.langTool(Gemini.self)!, model: model, serperApiKey: serperApiKey)
        case .ollama(let model):
            return ResearchAgent(langTool: langToolchain.langTool(Ollama.self)!, model: model, serperApiKey: serperApiKey)
        }
    }

    func updateApiKey(_ apiKey: String, for llm: APIService) throws {
        guard !apiKey.isEmpty else { throw NetworkError.emptyApiKey }
        keychainService.saveApiKey(apiKey: apiKey, for: llm)
        registerLangTool(apiKey, for: llm)
    }

    func registerLangTool(_ apiKey: String, for llm: APIService) {
        if let langTool = langTool(for: llm, with: apiKey) {
            langToolchain.register(langTool)
        }
    }

    func langTool(for llm: APIService, with apiKey: String) -> (any LangTools)? {
        let baseURL: URL? = nil //URL(string: "http://localhost:8080/v1/")
        switch llm {
        case .anthropic: return if let baseURL { Anthropic(baseURL: baseURL, apiKey: apiKey) } else { Anthropic(apiKey: apiKey) }
        case .openAI: return if let baseURL { OpenAI(baseURL: baseURL, apiKey: apiKey) } else { OpenAI(apiKey: apiKey) }
        case .xAI: return if let baseURL { XAI(baseURL: baseURL, apiKey: apiKey) } else { XAI(apiKey: apiKey) }
        case .gemini: return if let baseURL { Gemini(baseURL: baseURL, apiKey: apiKey) } else { Gemini(apiKey: apiKey) }
        case .ollama: return Ollama()
        default: return nil
        }
    }
}

enum APIService: String, CaseIterable {
    case openAI, anthropic, xAI, gemini, ollama, serper

    static var llms: [APIService] = [.openAI, .anthropic, .xAI, .gemini, .ollama]
}

extension NetworkClient {
    enum NetworkError: Error {
        case missingApiKey
        case emptyApiKey
        case incompatibleRequest
    }
}
