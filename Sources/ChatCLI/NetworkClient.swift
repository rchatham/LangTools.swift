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
#if canImport(AVFoundation)
import AVFoundation
#endif


typealias Role = OpenAI.Message.Role

class NetworkClient: NSObject, URLSessionWebSocketDelegate {
    static let shared = NetworkClient()

    private var userDefaults: UserDefaults { .standard }

    #if canImport(AVFoundation)
    private var audioPlayer: AVAudioPlayer?
    #endif

    override init() {
        super.init()
        APIService.allCases.forEach { llm in UserDefaults.getApiKey(for: llm).flatMap { register($0, for: llm) } }

        // Register Ollama without API key
        langToolchain.register(Ollama())
    }

    func request(messages: [Message], model: Model, stream: Bool = false, tools: [OpenAI.Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) -> any LangToolsChatRequest & LangToolsStreamableRequest {
        switch model {
        case .anthropic(let model):
            return Anthropic.MessageRequest(model: model, messages: messages.toAnthropicMessages(), stream: stream, tools: tools?.toAnthropicTools(), tool_choice: toolChoice?.toAnthropicToolChoice())
        case .openAI(let model):
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), n: 3, stream: stream, tools: tools, tool_choice: toolChoice, choose: {_ in 2})
        case .xAI(let model):
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream, tools: tools, tool_choice: toolChoice)
        case .gemini(let model):
            return OpenAI.ChatCompletionRequest(model: model, messages: messages.toOpenAIMessages(), stream: stream/*, tools: tools, tool_choice: toolChoice*/)
        case .ollama(let model):
            return Ollama.ChatRequest(model: model, messages: messages.toOllamaMessages(), format: nil, options: nil, stream: stream, keep_alive: nil, tools: tools)
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

    func langTool(for llm: APIService, with apiKey: String) -> any LangTools {
        let baseURL: URL? = nil //URL(string: "http://localhost:8080/v1/")
        switch llm {
        case .anthropic: return if let baseURL { Anthropic(baseURL: baseURL, apiKey: apiKey) } else { Anthropic(apiKey: apiKey) }
        case .openAI: return if let baseURL { OpenAI(baseURL: baseURL, apiKey: apiKey) } else { OpenAI(apiKey: apiKey) }
        case .xAI: return if let baseURL { XAI(baseURL: baseURL, apiKey: apiKey) } else { XAI(apiKey: apiKey) }
        case .gemini: return if let baseURL { Gemini(baseURL: baseURL, apiKey: apiKey) } else { Gemini(apiKey: apiKey) }
        }
    }

    // MARK: - Audio Playback

    func playAudio(for text: String) async throws {
        let audioReq = OpenAI.AudioSpeechRequest(model: .tts_1_hd, input: text, voice: .alloy, responseFormat: .mp3, speed: 1.2)
        let audioResponse: Data = try await langToolchain.perform(request: audioReq)

        #if canImport(AVFoundation) && os(macOS)
        do {
            audioPlayer = try AVAudioPlayer(data: audioResponse)
            guard let player = audioPlayer else {
                throw NetworkError.audioPlaybackFailed
            }
            player.prepareToPlay()
            player.play()

            // Wait for playback to complete
            while player.isPlaying {
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            }
        } catch {
            throw NetworkError.audioPlaybackFailed
        }
        #else
        print("Audio playback is not supported on this platform")
        #endif
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
    case openAI, anthropic, xAI, gemini
}

extension NetworkClient {
    enum NetworkError: Error {
        case missingApiKey
        case emptyApiKey
        case incompatibleRequest
        case audioPlaybackFailed
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

// MARK: - Message Extensions for Ollama

extension Array<Message> {
    func toOllamaMessages() -> [Ollama.Message] {
        return self.map { message in
            Ollama.Message(role: message.role.toOllamaRole(), content: message.text ?? "")
        }
    }
}

extension OpenAI.Message.Role {
    func toOllamaRole() -> Ollama.Role {
        switch self {
        case .assistant: return .assistant
        case .user: return .user
        case .system: return .system
        case .tool: return .tool
        case .function: return .tool
        }
    }
}

