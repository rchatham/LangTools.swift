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
    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message
    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error>
    func playAudio(for text: String) async throws
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext
    func updateApiKey(_ apiKey: String, for llm: APIService) throws
    func removeApiKey(for llm: APIService) throws
    func connectAccount(_ provider: AccountLoginProvider) async throws
    func disconnectAccount(_ provider: AccountLoginProvider) async throws
}

public protocol ConversationAwareNetworkClientProtocol: NetworkClientProtocol {
    func performChatCompletionRequest(messages: [Message], model: Model, conversationID: UUID, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message
    func streamChatCompletionRequest(messages: [Message], model: Model, conversationID: UUID, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error>
    func endConversation(id: UUID) async
}

extension NetworkClientProtocol {
    public func performChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) async throws -> Message {
        try await performChatCompletionRequest(messages: messages, model: model, tools: tools, toolChoice: toolChoice, toolEventHandler: toolEventHandler)
    }

    public func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = true, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) throws -> AsyncThrowingStream<String, Error> {
        try streamChatCompletionRequest(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice, toolEventHandler: toolEventHandler)
    }

    func request(messages: [Message], model: Model, stream: Bool = false, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) -> any LangToolsChatRequest & LangToolsStreamableRequest where Self: NetworkClient {
        self.request(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice, toolEventHandler: toolEventHandler)
    }

    func agentContext(messages: [Message], model: Model = UserDefaults.model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext {
        try agentContext(messages: messages, model: model, eventHandler: eventHandler)
    }
}

public class NetworkClient: NSObject, ConversationAwareNetworkClientProtocol {
    public static let shared: NetworkClientProtocol = NetworkClient()

    private let keychainService: KeychainService
    private let accountLoginService: AccountLoginService
    private let accountProxyTransport: AccountProxyTransportProtocol
    public let providerAccessManager: ProviderAccessManager

    private var userDefaults: UserDefaults { .standard }
    private var langToolchain = LangToolchain()
    private let conversationLock = NSLock()
    private var codexConversationIDs = Set<UUID>()

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

    public func performChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) async throws -> Message {
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

        let response = try await langToolchain.perform(request: request(messages: messages, model: model, tools: tools, toolChoice: toolChoice, toolEventHandler: toolEventHandler))
        guard let text = response.content?.text else {
            throw NetworkError.unexpectedResponseFormat
        }
        return Message(text: text, role: .assistant)
    }

    public func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = true, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) throws -> AsyncThrowingStream<String, Error> {
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

        return try langToolchain.stream(request: request(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice, toolEventHandler: toolEventHandler)).compactMapAsyncThrowingStream { $0.content?.text }
    }

    public func performChatCompletionRequest(
        messages: [Message],
        model: Model,
        conversationID: UUID,
        tools: [Tool]?,
        toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?,
        toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }
    ) async throws -> Message {
        try ensureModelAccess(for: model)
        guard case .codex = model,
              let session = accountSession(for: model),
              let transport = accountProxyTransport as? ConversationAwareAccountProxyTransportProtocol
        else {
            return try await performChatCompletionRequest(messages: messages, model: model, tools: tools, toolChoice: toolChoice, toolEventHandler: toolEventHandler)
        }
        rememberCodexConversation(conversationID)
        return try await transport.performChatCompletionRequest(
            messages: messages,
            model: model,
            session: session,
            conversationID: conversationID,
            tools: tools,
            toolChoice: toolChoice
        )
    }

    public func streamChatCompletionRequest(
        messages: [Message],
        model: Model,
        conversationID: UUID,
        stream: Bool,
        tools: [Tool]?,
        toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?,
        toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }
    ) throws -> AsyncThrowingStream<String, Error> {
        try ensureModelAccess(for: model)
        guard case .codex = model,
              let session = accountSession(for: model),
              let transport = accountProxyTransport as? ConversationAwareAccountProxyTransportProtocol
        else {
            return try streamChatCompletionRequest(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice, toolEventHandler: toolEventHandler)
        }
        rememberCodexConversation(conversationID)
        return try transport.streamChatCompletionRequest(
            messages: messages,
            model: model,
            session: session,
            conversationID: conversationID,
            stream: stream,
            tools: tools,
            toolChoice: toolChoice
        )
    }

    public func endConversation(id: UUID) async {
        guard takeCodexConversation(id),
              let transport = accountProxyTransport as? ConversationAwareAccountProxyTransportProtocol
        else { return }
        await transport.endConversation(id: id)
    }

    private func rememberCodexConversation(_ id: UUID) {
        conversationLock.lock()
        codexConversationIDs.insert(id)
        conversationLock.unlock()
    }

    private func takeCodexConversation(_ id: UUID) -> Bool {
        conversationLock.lock()
        defer { conversationLock.unlock() }
        return codexConversationIDs.remove(id) != nil
    }

    public func playAudio(for text: String) async throws {
        let audioReq = OpenAI.AudioSpeechRequest(model: .tts_1_hd, input: text, voice: .alloy, responseFormat: .mp3, speed: 1.2)
        let audioResponse: Data = try await langToolchain.perform(request: audioReq)
        do { try AudioPlayer.shared.play(data: audioResponse) }
        catch { print(error.localizedDescription) }
    }

    func request(messages: [Message], model: Model, stream: Bool = false, tools: [Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) -> any LangToolsChatRequest & LangToolsStreamableRequest {
        switch model {
        case .anthropic(let model), .claudeCode(let model): return Anthropic.MessageRequest(model: model, messages: messages.toAnthropicMessages(), stream: stream, system: messages.createAnthropicSystemMessage(), tools: tools?.convertTools(), tool_choice: toolChoice?.toAnthropicToolChoice(), toolEventHandler: toolEventHandler)
        case .openAI(let model), .codex(let model): return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), /*n: 3,*/ stream: stream, tools: tools?.convertTools(), tool_choice: toolChoice, toolEventHandler: toolEventHandler/*, choose: {_ in 2}*/)
        case .xAI(let model): return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools?.convertTools(), tool_choice: toolChoice, toolEventHandler: toolEventHandler)
        case .gemini(let model): return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, toolEventHandler: toolEventHandler/*, tools: tools?.convertTools(), tool_choice: toolChoice*/)
        case .ollama(let model): return Ollama.ChatRequest(model: model, messages: messages.toOllamaMessages(), format: nil, options: nil, stream: stream, keep_alive: nil, tools: tools?.convertTools(), toolEventHandler: toolEventHandler)
        }
    }

    public func agentContext(messages: [Message], model: Model = UserDefaults.model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext {
        try ensureModelAccess(for: model)
        if accountSession(for: model) != nil {
            throw NetworkError.accountProxyTransportFailed("Account-backed agent execution is not supported. Use an API key for agent runs.")
        }
        switch model {
        case .anthropic(let model), .claudeCode(let model): return AgentContext(langTool: try requiredLangTool(Anthropic.self), model: model, messages: messages.toAnthropicMessages(), eventHandler: eventHandler)
        case .gemini(let model): return AgentContext(langTool: try requiredLangTool(Gemini.self), model: model, messages: messages.toOpenAIMessages(), eventHandler: eventHandler)
        case .openAI(let model), .codex(let model): return AgentContext(langTool: try requiredLangTool(OpenAI.self), model: model, messages: messages.toOpenAIMessages(), eventHandler: eventHandler)
        case .xAI(let model): return AgentContext(langTool: try requiredLangTool(XAI.self), model: model, messages: messages.toOpenAIMessages(), eventHandler: eventHandler)
        case .ollama(let model): return AgentContext(langTool: try requiredLangTool(Ollama.self), model: model, messages: messages.toOllamaMessages(), eventHandler: eventHandler)
        }
    }

    private func requiredLangTool<T: LangTools>(_ type: T.Type) throws -> T {
        guard let tool = langToolchain.langTool(type) else {
            throw NetworkError.langToolNotRegistered(String(describing: type))
        }
        return tool
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
        try await MainActor.run {
            try providerAccessManager.saveAccountSession(session)
        }
    }

    public func disconnectAccount(_ provider: AccountLoginProvider) async throws {
        do {
            try await accountLoginService.logout(provider: provider)
        } catch {
            NSLog("Remote %@ logout failed; clearing the local session: %@", provider.displayName, error.localizedDescription)
        }
        try await MainActor.run {
            try providerAccessManager.removeAccountSession(for: provider)
        }
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
    private func ensureModelAccess(for model: Model) throws {
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

        guard state.availableModels.contains(model) else {
            throw NetworkError.modelAccessUnavailable(model.rawValue)
        }
    }

    private func accountSession(for model: Model) -> AccountSession? {
        guard let provider = model.apiService.accountLoginProvider else {
            return nil
        }

        switch model {
        case .codex, .claudeCode:
            return providerAccessManager.session(for: provider)
        case .openAI, .anthropic:
            return nil
        default:
            return nil
        }
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
        case unexpectedResponseFormat
        case langToolNotRegistered(String)

        public var errorDescription: String? {
            switch self {
            case .missingApiKey:
                return "This provider is not configured. Add an API key or connect an account in Manage Access so its models appear in the picker."
            case .emptyApiKey:
                return "API key cannot be empty."
            case .incompatibleRequest:
                return "The selected request is incompatible with the current provider."
            case .modelAccessUnavailable(let modelID):
                return "Your current credentials do not include access to \(modelID)."
            case .accountProxyTransportFailed(let message):
                return message
            case .unexpectedResponseFormat:
                return "The API returned a response in an unexpected format."
            case .langToolNotRegistered(let name):
                return "\(name) is not registered. Provide an API key to enable this provider."
            }
        }
    }
}
