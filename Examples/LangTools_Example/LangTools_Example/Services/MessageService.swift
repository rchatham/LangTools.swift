//
//  MessageService.swift
//
//  Created by Reid Chatham on 3/31/23.
//

import Foundation
import LangTools
import OpenAI
import Anthropic
import XAI
import Gemini
import Ollama
import Agents

@Observable
class MessageService {
    let networkClient: NetworkClient
    var messages: [Message] = []

    init(networkClient: NetworkClient = NetworkClient.shared) {
        self.networkClient = networkClient
    }

    var tools: [OpenAI.Tool]? {
        return [
            .function(.init(
                name: "getCurrentWeather",
                description: "Get the current weather",
                parameters: .init(
                    properties: [
                        "location": .init(
                            type: "string",
                            description: "The city and state, e.g. San Francisco, CA"),
                        "format": .init(
                            type: "string",
                            enumValues: ["celsius", "fahrenheit"],
                            description: "The temperature unit to use. Infer this from the users location.")
                    ],
                    required: ["location", "format"]),
                callback: { [weak self] in
                    self?.getCurrentWeather(location: $0["location"]! as! String, format: $0["format"]! as! String)
                })),
            .function(.init(
                name: "getAnswerToUniverse",
                description: "The answer to the universe, life, and everything.",
                parameters: .init(),
                callback: { _ in
                    "42"
                })),
            .function(.init(
                name: "getTopMichelinStarredRestaurants",
                description: "Get the top Michelin starred restaurants near a location",
                parameters: .init(
                    properties: [
                        "location": .init(
                            type: "string",
                            description: "The city and state, e.g. San Francisco, CA")
                    ],
                    required: ["location"]),
                callback: { [weak self] in
                    self?.getTopMichelinStarredRestaurants(location: $0["location"]! as! String)
                })),

            // Calendar agent tool
            .function(.init(
                name: "manage_calendar",
                description: """
                    Manage calendar events - create, read, update, or delete calendar events. 
                    Can handle natural language requests like "Schedule a meeting tomorrow" or 
                    "What's on my calendar next week?"
                    """,
                parameters: .init(
                    properties: [
                        "request": .init(
                            type: "string",
                            description: "The calendar-related request in natural language"
                        )
                    ],
                    required: ["request"]),
                callback: { [weak self] args in
                    guard let request = args["request"] as? String else {
                        return "Invalid calendar request"
                    }
                    return await self?.networkClient.handleCalendarRequest(request)
                }))
        ]
    }

    func performMessageCompletionRequest(message: String, stream: Bool = false) async throws {
        do { try await getChatCompletion(for: message, stream: stream) }
        catch let error as LangToolError {
            switch error {
            case .jsonParsingFailure(let error): print("error: json parsing error: \(error.localizedDescription)")
            case .apiError(let error): handleApiError(error)
            case .invalidData: print("error: invalid data")
            case .invalidURL: print("error: invalid url")
            case .requestFailed: print("Request failed")
            case .responseUnsuccessful(statusCode: let code, let error):
                print("response unsuccessful - status code: \(code)")
                if let error { handleApiError(error) }
            case .streamParsingFailure: print("error: stream parsing failure")
            case .failiedToDecodeStream(buffer: let buffer, error: let error):
                print("Failed to decode stream: \(buffer), error: \(error.localizedDescription)")
            case .invalidContentType: print("error: invalid content type")
            }
        }
        catch let error as LangToolsRequestError {
            switch error {
            case .multipleChoiceIndexOutOfBounds: print("multiple choice index out of bounds")
            case .failedToDecodeFunctionArguments: print("error: failed to decode function args")
            case .missingRequiredFunctionArguments: print("error: missing args")
            }
        }
    }

    func handleApiError(_ error: Error) {
        switch error {
        case let error as OpenAIErrorResponse:
            print("error: openai api error: \(error.error)")
        case let error as XAIErrorResponse:
            print("error: xai api error: \(error.error)")
        case let error as GeminiErrorResponse:
            print("error: gemini api error: \(error.error)")
        case let error as AnthropicErrorResponse:
            print("error: anthropic api error: \(error.error)")
        case let error as OllamaErrorResponse:
            print("error: ollama api error: \(error.error)")
        default: print("error: uanble to decode error: \(error)")
        }
    }

    func getChatCompletion(for message: String, stream: Bool) async throws {
        await MainActor.run {
            messages.append(Message(text: message, role: .user))
        }

        let toolChoice = (tools?.isEmpty ?? true) ? nil : OpenAI.ChatCompletionRequest.ToolChoice.auto
        let uuid = UUID(); var content: String = ""
        for try await chunk in try networkClient.streamChatCompletionRequest(messages: messages, stream: stream, tools: tools, toolChoice: toolChoice) {

            guard let last = messages.last else { continue }

            content += chunk
            let message = Message(uuid: uuid, text: content.trimingTrailingNewlines(), role: .assistant)

            await MainActor.run {
                if last.uuid == uuid {
                    messages[messages.count - 1] = message
                } else {
                    messages.append(message)
                }
            }
        }

        if messages.last?.uuid == uuid, let text = messages.last?.text {
            Task {
                try await networkClient.playAudio(for: text)
            }
        }
    }

    func deleteMessage(id: UUID) {
        messages.removeAll(where: { $0.uuid == id })
    }

    @objc func getCurrentWeather(location: String, format: String) -> String {
        return "27"
    }

    func getTopMichelinStarredRestaurants(location: String) -> String {
        return "The French Laundry"
    }
}
