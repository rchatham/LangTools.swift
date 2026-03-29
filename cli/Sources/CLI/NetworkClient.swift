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

    private var userDefaults: UserDefaults { .standard }

    override init() {
        super.init()
        // Register cloud providers that have stored API keys
        APIService.allCases.filter { $0 != .ollama }.forEach { llm in
            UserDefaults.getApiKey(for: llm).flatMap { register($0, for: llm) }
        }
        // Ollama runs locally — always register it (no API key required)
        registerOllama()
    }

    func request(messages: [Message], model: Model, stream: Bool = false, tools: [OpenAI.Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) -> any LangToolsChatRequest & LangToolsStreamableRequest {
        if case .anthropic(let model) = model {
            return Anthropic.MessageRequest(model: model, messages: messages.toAnthropicMessages(), stream: stream, tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice())
        } else if case .openAI(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), n: 3, stream: stream, tools: tools, tool_choice: toolChoice, choose: {_ in 2})
        } else if case .xAI(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice)
        } else if case .gemini(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream/*, tools: tools, tool_choice: toolChoice*/)
        } else if case .ollama(let model) = model {
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice)
        } else {
            return Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages.toAnthropicMessages(), stream: stream, tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice())
        }
    }

    func updateApiKey(_ apiKey: String, for llm: APIService) throws {
        guard !apiKey.isEmpty else { throw NetworkError.emptyApiKey }
        UserDefaults.setApiKey(apiKey, for: llm)
        register(apiKey, for: llm)
    }

    func register(_ apiKey: String, for llm: APIService) {
        langToolchain.register(langTool(for: llm, with: apiKey))
    }

    /// Register Ollama without an API key (local server, no auth needed).
    func registerOllama(baseURL: URL = URL(string: "http://localhost:11434")!) {
        langToolchain.register(Ollama(baseURL: baseURL))
    }

    /// Fetch the locally-available Ollama models and populate `OllamaModel.allCases`.
    /// Silently does nothing if Ollama is not running.
    func fetchOllamaModels() async {
        guard let ollama = langToolchain.langTool(Ollama.self) else { return }
        do {
            let response = try await ollama.listModels()
            OllamaModel.allCases = response.models.compactMap { OllamaModel(rawValue: $0.name) }
        } catch {
            // Ollama may not be running — that's fine, just leave allCases empty
        }
    }

    func langTool(for llm: APIService, with apiKey: String) -> any LangTools {
        let baseURL: URL? = nil //URL(string: "http://localhost:8080/v1/")
        switch llm {
        case .anthropic: return if let baseURL { Anthropic(baseURL: baseURL, apiKey: apiKey) } else { Anthropic(apiKey: apiKey) }
        case .openAI: return if let baseURL { OpenAI(baseURL: baseURL, apiKey: apiKey) } else { OpenAI(apiKey: apiKey) }
        case .xAI: return if let baseURL { XAI(baseURL: baseURL, apiKey: apiKey) } else { XAI(apiKey: apiKey) }
        case .gemini: return if let baseURL { Gemini(baseURL: baseURL, apiKey: apiKey) } else { Gemini(apiKey: apiKey) }
        case .ollama: return Ollama()
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        // No-op implementation to satisfy URLSessionWebSocketDelegate protocol requirements
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // No-op implementation to satisfy URLSessionWebSocketDelegate protocol requirements
    }
}

enum APIService: String, CaseIterable {
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
