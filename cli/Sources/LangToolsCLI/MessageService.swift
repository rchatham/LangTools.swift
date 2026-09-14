//
//  MessageService.swift
//
//  Created by Reid Chatham on 3/31/23.
//

import Anthropic
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Gemini
import LangTools
import OpenAI
import XAI
#if canImport(SwiftUI)
import SwiftUI
#endif

class MessageService: ObservableObject {
    var messages: [Message] = []

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
                callback: { [weak self] info, params in
                    self?.getCurrentWeather(location: params["location"]!.stringValue!, format: params["format"]!.stringValue!)
                })),
            .function(.init(
                name: "getAnswerToUniverse",
                description: "The answer to the universe, life, and everything.",
                parameters: .init(),
                callback: { _,_ in
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
                callback: { [weak self] info, params in
                    self?.getTopMichelinStarredRestaurants(location: params["location"]!.stringValue!)
                }))
        ]
    }

    func performMessageCompletionRequest(message: String, stream: Bool = false) async throws {
        do {
            try await getChatCompletion(for: message, stream: stream)
        } catch let error as LangToolsError {
            handleLangToolsError(error)
        } catch let error as LangToolsRequestError {
            handleLangToolsRequestError(error)
        } catch {
            print("Unexpected error: \(error.localizedDescription)")
            throw error
        }
    }

    func getChatCompletion(for message: String, stream: Bool) async throws {
        await MainActor.run {
            messages.append(Message(text: message, role: .user))
        }

        let toolChoice = (tools?.isEmpty ?? true) ? nil : OpenAI.ChatCompletionRequest.ToolChoice.auto
        print("\rAssistant: ".yellow, terminator: "")
        let uuid = UUID(); var content: String = ""
        let stream = try streamChatCompletionRequest(
            messages: messages,
            stream: stream,
            tools: tools,
            toolChoice: toolChoice
        )
        for try await chunk in stream {
            // hack to print new lines as long as they aren't the last one
            if content.hasSuffix("\n") {
                print("")
            }

            await MainActor.run {
                print("\(chunk.trimingTrailingNewlines())", terminator: "")
            }
            fflush(stdout)

            content += chunk
            let message = Message(uuid: uuid, text: content.trimingTrailingNewlines(), role: .assistant)

            if let last = messages.last, last.uuid == uuid {
                messages[messages.endIndex - 1] = message
            } else {
                messages.append(message)
            }
        }

        print("") // Add a newline after the complete response
    }

    func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = true, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<String, Error> {
        return try langToolchain.stream(request: networkClient.request(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)).compactMapAsyncThrowingStream { $0.content?.text }
    }

    func handleLangToolsError(_ error: LangToolsError) {
        switch error {
        case .jsonParsingFailure(let error):
            print("JSON parsing error: \(error.localizedDescription)")
        case .apiError(let error):
            handleLangToolApiError(error)
        case .invalidData:
            print("Invalid data received from API")
        case .invalidURL:
            print("Invalid URL configuration")
        case .requestFailed:
            print("Request failed")
        case .responseUnsuccessful(let code, let error):
            print("API response unsuccessful status code: \(code)")
            if let error { handleLangToolApiError(error) }
        case .streamParsingFailure:
            print("Failed to parse streaming response")
        case .failedToDecodeStream(let buffer, let error):
            print("Failed to decode stream: \(buffer), error: \(error.localizedDescription)")
        case .invalidContentType:
            print("Invalid content type")
        default: break
        }
    }

    func handleLangToolApiError(_ error: Error) {
        switch error {
        case let error as OpenAIErrorResponse:
            print("OpenAI API error: \(error.error)")
        case let error as XAIErrorResponse:
            print("XAI API error: \(error.error)")
        case let error as GeminiErrorResponse:
            print("Gemini API error: \(error.error)")
        case let error as AnthropicErrorResponse:
            print("Anthropic API error: \(error.error)")
        default:
            print("Unknown API error: \(error)")
        }
    }

    func handleLangToolsRequestError(_ error: LangToolsRequestError) {
        switch error {
        case .multipleChoiceIndexOutOfBounds:
            print("Multiple choice index out of bounds")
        case .failedToDecodeFunctionArguments:
            print("Failed to decode function arguments")
        case .missingRequiredFunctionArguments:
            print("Missing required function arguments")
        }
    }

    func deleteMessage(id: UUID) {
        messages.removeAll(where: { $0.uuid == id })
    }

    #if canImport(Darwin)
    @objc
    #endif
    func getCurrentWeather(location: String, format: String) -> String {
        return "27"
    }

    func getTopMichelinStarredRestaurants(location: String) -> String {
        return "The French Laundry"
    }
}
