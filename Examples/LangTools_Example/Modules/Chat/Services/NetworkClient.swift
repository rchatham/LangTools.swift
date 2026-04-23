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
    var providerAccessManager: ProviderAccessManager { get }
    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message
    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error>
    func playAudio(for text: String) async throws
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext
    func updateApiKey(_ apiKey: String, for llm: APIService) throws
    func removeApiKey(for llm: APIService) throws
    func connectAccount(_ provider: AccountLoginProvider) async throws
    func disconnectAccount(_ provider: AccountLoginProvider) async throws
}

extension NetworkClientProtocol {
    public func performChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) async throws -> Message {
        try await performChatCompletionRequest(messages: messages, model: model, tools: tools, toolChoice: toolChoice)
    }

    public func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = true, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<String, Error> {
        try streamChatCompletionRequest(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)
    }

    func request(messages: [Message], model: Model, stream: Bool = false, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) -> any LangToolsChatRequest & LangToolsStreamableRequest where Self: NetworkClient {
        self.request(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)
    }

    func agentContext(messages: [Message], model: Model = UserDefaults.model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext {
        try agentContext(messages: messages, model: model, eventHandler: eventHandler)
    }
}

public class NetworkClient: NSObject, NetworkClientProtocol {
    public static let shared: NetworkClientProtocol = NetworkClient()

    private let keychainService: KeychainService
    private let accountLoginService: AccountLoginService
    private let accountProxyTransport: AccountProxyTransportProtocol
    public let providerAccessManager: ProviderAccessManager

    private var userDefaults: UserDefaults { .standard }
    private var langToolchain = LangToolchain()

    public init(
        keychainService: KeychainService = .shared,
        accountLoginService: AccountLoginService = BrowserAccountLoginService.shared,
        accountProxyTransport: AccountProxyTransportProtocol = AccountProxyTransport(),
        providerAccessManager: ProviderAccessManager = .shared
    ) {
        self.keychainService = keychainService
        self.accountLoginService = accountLoginService
        self.accountProxyTransport = accountProxyTransport
        self.providerAccessManager = providerAccessManager
        super.init()
        APIService.llms.forEach { llm in keychainService.getApiKey(for: llm).flatMap { registerLangTool($0, for: llm) } }

        // For Ollama, we don't need an API key
        langToolchain.register(Ollama())

        // Initialize Ollama service to start populating available models
        _ = OllamaService.shared
        providerAccessManager.refresh()
    }

    public func performChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) async throws -> Message {
        try ensureModelAccess(for: model)

        if let session = accountSession(for: model) {
            return try await accountProxyTransport.performChatCompletionRequest(
                messages: messages,
                model: model,
                session: session,
                tools: tools,
                toolChoice: toolChoice
            )
        }

        let response = try await langToolchain.perform(request: request(messages: messages, model: model, tools: tools, toolChoice: toolChoice))
        guard let text = response.content?.text else { fatalError("the api should never return non text") }
        return Message(text: text, role: .assistant)
    }

    public func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = true, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<String, Error> {
        try ensureModelAccess(for: model)

        if let session = accountSession(for: model) {
            return try accountProxyTransport.streamChatCompletionRequest(
                messages: messages,
                model: model,
                session: session,
                stream: stream,
                tools: tools,
                toolChoice: toolChoice
            )
        }

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
        case .anthropic(let model): return Anthropic.MessageRequest(model: model, messages: messages.toAnthropicMessages(), stream: stream, system: messages.createAnthropicSystemMessage(), tools: tools?.convertTools(), tool_choice: toolChoice?.toAnthropicToolChoice())
        case .openAI(let model): return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), /*n: 3,*/ stream: stream, tools: tools?.convertTools(), tool_choice: toolChoice/*, choose: {_ in 2}*/)
        case .xAI(let model): return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools?.convertTools(), tool_choice: toolChoice)
        case .gemini(let model): return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream/*, tools: tools?.convertTools(), tool_choice: toolChoice*/)
        case .ollama(let model): return Ollama.ChatRequest(model: model, messages: messages.toOllamaMessages(), format: nil, options: nil, stream: stream, keep_alive: nil, tools: tools?.convertTools())
        }
    }

    public func agentContext(messages: [Message], model: Model = UserDefaults.model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext {
        try ensureModelAccess(for: model)
        if accountSession(for: model) != nil {
            throw NetworkError.accountProxyTransportFailed("Account-backed agent execution is not implemented yet. Use an API key for agent runs.")
        }
        switch model {
        case .anthropic(let model): return AgentContext(langTool: langToolchain.langTool(Anthropic.self)!, model: model, messages: messages.toAnthropicMessages(), eventHandler: eventHandler)
        case .gemini(let model): return AgentContext(langTool: langToolchain.langTool(Gemini.self)!, model: model, messages: messages.toOpenAIMessages(), eventHandler: eventHandler)
        case .openAI(let model): return AgentContext(langTool: langToolchain.langTool(OpenAI.self)!, model: model, messages: messages.toOpenAIMessages(), eventHandler: eventHandler)
        case .xAI(let model): return AgentContext(langTool: langToolchain.langTool(XAI.self)!, model: model, messages: messages.toOpenAIMessages(), eventHandler: eventHandler)
        case .ollama(let model): return AgentContext(langTool: langToolchain.langTool(Ollama.self)!, model: model, messages: messages.toOpenAIMessages(), eventHandler: eventHandler)
        }
    }

    public func updateApiKey(_ apiKey: String, for llm: APIService) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NetworkError.emptyApiKey }
        keychainService.saveApiKey(apiKey: apiKey, for: llm)
        registerLangTool(apiKey, for: llm)
        providerAccessManager.refresh()
    }

    public func removeApiKey(for llm: APIService) throws {
        keychainService.deleteApiKey(for: llm)
        providerAccessManager.refresh()
    }

    public func connectAccount(_ provider: AccountLoginProvider) async throws {
        let session = try await accountLoginService.beginLogin(for: provider)
        try providerAccessManager.saveAccountSession(session)
    }

    public func disconnectAccount(_ provider: AccountLoginProvider) async throws {
        try await accountLoginService.logout(provider: provider)
        try providerAccessManager.removeAccountSession(for: provider)
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
    func ensureModelAccess(for model: Model) throws {
        let state = providerAccessManager.state(for: model.apiService)

        switch model.apiService {
        case .ollama:
            return
        case .serper:
            throw NetworkError.incompatibleRequest
        default:
            break
        }

        if state.authStatus == .notConfigured {
            throw NetworkError.missingApiKey
        }

        if !state.availableModels.isEmpty, state.availableModels.contains(model) == false {
            throw NetworkError.modelAccessUnavailable(model.rawValue)
        }
    }

    private func accountSession(for model: Model) -> AccountSession? {
        let state = providerAccessManager.state(for: model.apiService)
        guard state.hasAccountSession, state.hasAPIKey == false,
              let provider = model.apiService.accountLoginProvider
        else {
            return nil
        }
        return providerAccessManager.session(for: provider)
    }
}

public enum APIService: String, CaseIterable, Codable, Identifiable {
    case openAI, anthropic, xAI, gemini, ollama, serper

    public var id: String { rawValue }

    static var llms: [APIService] = [.openAI, .anthropic, .xAI, .gemini, .ollama]
}

extension NetworkClient {
    public enum NetworkError: LocalizedError, Equatable {
        case missingApiKey
        case emptyApiKey
        case incompatibleRequest
        case modelAccessUnavailable(String)
        case accountProxyTransportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingApiKey:
                return "This provider is not configured. Add an API key or connect an account in Manage Access."
            case .emptyApiKey:
                return "API key cannot be empty."
            case .incompatibleRequest:
                return "The selected request is incompatible with the current provider."
            case .modelAccessUnavailable(let modelID):
                return "Your current credentials do not include access to \(modelID)."
            case .accountProxyTransportFailed(let message):
                return message
            }
        }
    }
}
