//
//  NetworkClient.swift
//
//  Created by Reid Chatham on 1/20/23.
//

import Foundation
import HelperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
import OpenAICompatible
import Anthropic
import XAI
import Gemini
import Cohere
import Ollama
#if canImport(AVFAudio)
import AVFAudio
#endif

typealias Role = OpenAI.Message.Role

class NetworkClient: NSObject, URLSessionWebSocketDelegate {
    static let shared = NetworkClient()

    private let sessionStore = SessionStore()
    private var userDefaults: UserDefaults { .standard }

    override init() {
        super.init()
        refreshCredentials()
    }

    func refreshCredentials() {
        APIService.allCases.filter { $0 != .ollama }.forEach { llm in
            if let apiKey = UserDefaults.getApiKey(for: llm) {
                register(apiKey, for: llm)
            }
        }

        if UserDefaults.getApiKey(for: .openAI) == nil,
           let session = try? sessionStore.load() {
            register(session.accessToken, for: .openAI)
        }

        registerOllama()
    }

    func request(
        messages: [Message],
        model: Model,
        stream: Bool = false,
        tools: [OpenAI.Tool]?,
        toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?,
        toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }
    ) -> any LangToolsChatRequest & LangToolsStreamableRequest {
        if case .anthropic(let model) = model {
            return Anthropic.MessageRequest(model: model, messages: messages.toAnthropicMessages(), stream: stream, system: messages.toAnthropicSystemMessage(), tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice(), toolEventHandler: toolEventHandler)
        } else if case .openAI(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice, toolEventHandler: toolEventHandler)
        } else if case .xAI(let model) = model {
            return OpenAI.ChatCompletionRequest(model: OpenAI.Model(customModelID: model.rawValue), messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice, toolEventHandler: toolEventHandler)
        } else if case .gemini(let model) = model {
            return Gemini.GenerateContentRequest(model: model, messages: messages.toOpenAIMessages().map { Gemini.Message($0) }, stream: stream, tools: tools, functionCallingMode: toolChoice.map { .init($0) }, toolEventHandler: toolEventHandler)
        } else if case .ollama(let model) = model {
            return Ollama.ChatRequest(model: model, messages: messages.toOllamaMessages(), stream: stream, tools: tools, toolEventHandler: toolEventHandler)
        } else if case .compatible(let provider, let id) = model {
            // The tagged model routes to the provider rather than to OpenAI.
            if provider == .cohere, let model = Cohere.Model(rawValue: id) {
                return Cohere.ChatRequest(model: model, messages: messages.toOpenAIMessages().map { Cohere.Message($0) }, stream: stream, tools: tools, tool_choice: toolChoice.flatMap { .init($0) }, toolEventHandler: toolEventHandler)
            }
            if provider.usesResponses {
                return OpenAI.ResponsesRequest(model: provider.openAIModel(id: id), messages: messages.toOpenAIMessages(), stream: stream, tools: tools, toolEventHandler: toolEventHandler)
            }
            return OpenAI.ChatCompletionRequest(model: provider.openAIModel(id: id), messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice, toolEventHandler: toolEventHandler)
        } else {
            return Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages.toAnthropicMessages(), stream: stream, system: messages.toAnthropicSystemMessage(), tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice(), toolEventHandler: toolEventHandler)
        }
    }

    func updateApiKey(_ apiKey: String, for llm: APIService) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NetworkError.emptyApiKey }
        UserDefaults.setApiKey(trimmed, for: llm)
        register(trimmed, for: llm)
    }

    func register(_ apiKey: String, for llm: APIService) {
        langToolchain.register(langTool(for: llm, with: apiKey))
    }

    /// Registers the Ollama provider. Local models target the local daemon;
    /// `:cloud`-suffixed models route to ollama.com with the Ollama API key
    /// (from `OLLAMA_API_KEY` or a stored key) so they work even when the
    /// local daemon is not running.
    func registerOllama(baseURL: URL = URL(string: "http://localhost:11434")!) {
        let cloudKey = ProcessInfo.processInfo.environment["OLLAMA_API_KEY"]
            ?? UserDefaults.getApiKey(for: .ollama)
        let ollama: Ollama
        if let cloudKey, !cloudKey.isEmpty {
            ollama = Ollama(
                baseURL: baseURL,
                apiKey: cloudKey,
                cloudBaseURL: URL(string: "https://ollama.com")!,
                cloudAPIKey: cloudKey
            )
        } else {
            ollama = Ollama(baseURL: baseURL)
        }
        langToolchain.register(ollama)
    }

    func fetchOllamaModels() async {
        guard let ollama = langToolchain.langTool(Ollama.self) else { return }
        do {
            let response = try await ollama.listModels()
            OllamaModel.allCases = response.models.compactMap { OllamaModel(rawValue: $0.name) }
        } catch {
            // Ollama may not be running — that's fine.
        }
    }

    /// Loads chat-model catalogs for the configured OpenAI-compatible providers
    /// into `Model.compatibleCatalogs`. A provider without a catalog endpoint,
    /// or one that cannot be reached, offers its suggested models.
    func fetchCompatibleModels() async {
        let toolchain = langToolchain
        var catalogs: [CompatibleProvider: [OpenAICompatibleModelInfo]] = [:]
        await withTaskGroup(of: (CompatibleProvider, [OpenAICompatibleModelInfo]?).self) { group in
            for provider in CompatibleProvider.allCases {
                group.addTask { (provider, await provider.chatModelCatalog(toolchain: toolchain)) }
            }
            for await (provider, catalog) in group {
                if let catalog { catalogs[provider] = catalog }
            }
        }
        Model.compatibleCatalogs = catalogs
    }

    func langTool(for llm: APIService, with apiKey: String) -> any LangTools {
        let baseURL: URL? = nil
        switch llm {
        case .anthropic: return if let baseURL { Anthropic(baseURL: baseURL, apiKey: apiKey) } else { Anthropic(apiKey: apiKey) }
        case .openAI: return if let baseURL { OpenAI(baseURL: baseURL, apiKey: apiKey) } else { OpenAI(apiKey: apiKey) }
        case .xAI: return if let baseURL { XAI(baseURL: baseURL, apiKey: apiKey) } else { XAI(apiKey: apiKey) }
        case .gemini: return if let baseURL { Gemini(baseURL: baseURL, apiKey: apiKey) } else { Gemini(apiKey: apiKey) }
        case .ollama: return Ollama()
        case .openrouter, .vercel, .groq, .mistral, .deepseek, .cerebras, .together, .fireworks, .cohere, .perplexity:
            return CompatibleProvider(apiService: llm)!.makeClient(apiKey: apiKey)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {}

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
}

enum APIService: String, CaseIterable {
    case openAI, anthropic, xAI, gemini, ollama
    // OpenAI-compatible providers; raw values match `CompatibleProvider`.
    case openrouter, vercel, groq, mistral, deepseek, cerebras, together, fireworks, cohere, perplexity
}

extension NetworkClient {
    enum NetworkError: Error {
        case missingApiKey
        case emptyApiKey
        case incompatibleRequest
        case accountProxyTransportFailed(String)
    }
}

extension String {
    func trimingTrailingNewlines() -> String {
        trimingTrailingCharacters(using: .newlines)
    }

    func trimingTrailingCharacters(using characterSet: CharacterSet = .whitespacesAndNewlines) -> String {
        guard let index = lastIndex(where: { !CharacterSet(charactersIn: String($0)).isSubset(of: characterSet) }) else {
            return self
        }

        return String(self[...index])
    }
}
