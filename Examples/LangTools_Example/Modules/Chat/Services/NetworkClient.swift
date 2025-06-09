//
//  NetworkClient.swift
//
//  Created by Reid Chatham on 1/20/23.
//
import Foundation
import LangTools
import Agents
import OpenAI
import Anthropic
import XAI
import Gemini
import Ollama

public typealias Role = OpenAI.Message.Role

public protocol NetworkClientProtocol {
    static var shared: NetworkClientProtocol { get }
    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message
    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error>
    func playAudio(for text: String) async throws
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) -> AgentContext
    func updateApiKey(_ apiKey: String, for llm: APIService) throws
}

extension NetworkClientProtocol {
    public func performChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) async throws -> Message {
        try await performChatCompletionRequest(messages: messages, model: model, tools: tools, toolChoice: toolChoice)
    }

    public func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = true, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<String, Error> {
        try streamChatCompletionRequest(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)
    }

    func request(messages: [Message], model: Model, stream: Bool = false, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) -> any LangToolsChatRequest & LangToolsStreamableRequest {
        request(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)
    }

    func agentContext(messages: [Message], model: Model = UserDefaults.model, eventHandler: @escaping (AgentEvent) -> Void) -> AgentContext {
        agentContext(messages: messages, model: model, eventHandler: eventHandler)
    }
}

public class NetworkClient: NSObject, NetworkClientProtocol {
    public static let shared: NetworkClientProtocol = NetworkClient()

    private let keychainService = KeychainService()
    private var userDefaults: UserDefaults { .standard }

    private var langToolchain = LangToolchain()

    override init() {
        super.init()
        APIService.llms.forEach { llm in keychainService.getApiKey(for: llm).flatMap { registerLangTool($0, for: llm) } }

        // For Ollama, we don't need an API key
        langToolchain.register(Ollama())

        // Initialize Ollama service to start populating available models
        _ = OllamaService.shared
    }

    public func performChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) async throws -> Message {
        let response = try await langToolchain.perform(request: request(messages: messages, model: model, tools: tools, toolChoice: toolChoice))
        guard let text = response.content?.text else { fatalError("the api should never return non text") }
        return Message(text: text, role: .assistant)
    }

    public func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = true, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<String, Error> {
        return try langToolchain.stream(request: request(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)).compactMapAsyncThrowingStream { $0.content?.text }
    }

    public func playAudio(for text: String) async throws {
        let audioReq = OpenAI.AudioSpeechRequest(model: .tts_1_hd, input: text, voice: .alloy, responseFormat: .mp3, speed: 1.2)
        let audioResponse: Data = try await langToolchain.perform(request: audioReq)
        do { try AudioPlayer.shared.play(data: audioResponse) }
        catch { print(error.localizedDescription) }
    }

    func request(messages: [Message], model: Model, stream: Bool = false, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) -> any LangToolsChatRequest & LangToolsStreamableRequest {
        switch model {
        case .anthropic(let model):
            return Anthropic.MessageRequest(model: model, messages: messages.toAnthropicMessages(), stream: stream, system: messages.createAnthropicSystemMessage(), tools: tools?.convertTools(), tool_choice: toolChoice?.toAnthropicToolChoice())
        case .openAI(let model):
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), /*n: 3,*/ stream: stream, tools: tools?.convertTools(), tool_choice: toolChoice/*, choose: {_ in 2}*/)
        case .xAI(let model):
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools?.convertTools(), tool_choice: toolChoice)
        case .gemini(let model):
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream/*, tools: tools?.convertTools(), tool_choice: toolChoice*/)
        case .ollama(let model):
            return Ollama.ChatRequest(model: model, messages: messages.toOllamaMessages(), format: nil, options: nil, stream: stream, keep_alive: nil, tools: tools?.convertTools())
        }
    }

    public func agentContext(messages: [Message], model: Model = UserDefaults.model, eventHandler: @escaping (AgentEvent) -> Void) -> AgentContext {
        switch model {
        case .anthropic(let model):
            return AgentContext(langTool: langToolchain.langTool(Anthropic.self)!, model: model, messages: messages.toAnthropicMessages(), eventHandler: eventHandler)
        case .gemini(let model):
            return AgentContext(langTool: langToolchain.langTool(Gemini.self)!, model: model, messages: messages.toOpenAIMessages(), eventHandler: eventHandler)
        case .openAI(let model):
            return AgentContext(langTool: langToolchain.langTool(OpenAI.self)!, model: model, messages: messages.toOpenAIMessages(), eventHandler: eventHandler)
        case .xAI(let model):
            return AgentContext(langTool: langToolchain.langTool(XAI.self)!, model: model, messages: messages.toOpenAIMessages(), eventHandler: eventHandler)
        case .ollama(let model):
            return AgentContext(langTool: langToolchain.langTool(Ollama.self)!, model: model, messages: messages.toOpenAIMessages(), eventHandler: eventHandler)
        }
    }

    public func updateApiKey(_ apiKey: String, for llm: APIService) throws {
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

public enum APIService: String, CaseIterable {
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
