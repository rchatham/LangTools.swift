//
//  NetworkClient.swift
//
//  Created by Reid Chatham on 1/20/23.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
import Anthropic
import XAI
import Gemini
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
            return Anthropic.MessageRequest(model: model, messages: messages.toAnthropicMessages(), stream: stream, tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice(), toolEventHandler: toolEventHandler)
        } else if case .openAI(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice, toolEventHandler: toolEventHandler)
        } else if case .xAI(let model) = model {
            return OpenAI.ChatCompletionRequest(model: OpenAI.Model(customModelID: model.rawValue), messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice, toolEventHandler: toolEventHandler)
        } else if case .gemini(let model) = model {
            return OpenAI.ChatCompletionRequest(model: OpenAI.Model(customModelID: model.rawValue), messages: messages.toOpenAIMessages(), stream: stream, toolEventHandler: toolEventHandler)
        } else if case .ollama(let model) = model {
            return Ollama.ChatRequest(model: model, messages: messages.toOllamaMessages(), stream: stream, tools: tools, toolEventHandler: toolEventHandler)
        } else {
            return Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages.toAnthropicMessages(), stream: stream, tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice(), toolEventHandler: toolEventHandler)
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

    func registerOllama(baseURL: URL = URL(string: "http://localhost:11434")!) {
        langToolchain.register(Ollama(baseURL: baseURL))
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

    func langTool(for llm: APIService, with apiKey: String) -> any LangTools {
        let baseURL: URL? = nil
        switch llm {
        case .anthropic: return if let baseURL { Anthropic(baseURL: baseURL, apiKey: apiKey) } else { Anthropic(apiKey: apiKey) }
        case .openAI: return if let baseURL { OpenAI(baseURL: baseURL, apiKey: apiKey) } else { OpenAI(apiKey: apiKey) }
        case .xAI: return if let baseURL { XAI(baseURL: baseURL, apiKey: apiKey) } else { XAI(apiKey: apiKey) }
        case .gemini: return if let baseURL { Gemini(baseURL: baseURL, apiKey: apiKey) } else { Gemini(apiKey: apiKey) }
        case .ollama: return Ollama()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {}

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
}

enum APIService: String, CaseIterable {
    case openAI, anthropic, xAI, gemini, ollama
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
