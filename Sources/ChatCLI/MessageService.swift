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
                }))
        ]
    }

    func handleLangToolError(_ error: LangToolError) {
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
        case .failiedToDecodeStream(buffer: let buffer, error: let error):
            print("Failed to decode stream: \(buffer), error: \(error.localizedDescription)")
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

    @objc func getCurrentWeather(location: String, format: String) -> String {
        return "27"
    }

    func getTopMichelinStarredRestaurants(location: String) -> String {
        return "The French Laundry"
    }
}
