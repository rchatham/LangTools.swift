//
//  MessageService.swift
//
//  Created by Reid Chatham on 3/31/23.
//

import Foundation
import LangTools
import OpenAI

@Observable
class MessageService {
    let networkClient: NetworkClient
    var messages: [Message] = [] {
        didSet {
            print("messages updated: \(messages)")
        }
    }

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
                }))
        ]
    }

    func performMessageCompletionRequest(message: String, stream: Bool = false) async throws {
        do {
            try await getChatCompletion(for: message, stream: stream)
        } catch let error as LangToolError<OpenAIErrorResponse> {
            switch error {
            case .jsonParsingFailure(let error): print("error: json parsing error: \(error.localizedDescription)")
            case .apiError(let error): print("error: openai api error: \(error.error)")
            case .invalidData: print("error: invalid data")
            case .invalidURL: print("error: invalid url")
            case .requestFailed(let error): print("error: request failed with error: \(error?.localizedDescription ?? "no error")")
            case .responseUnsuccessful(statusCode: let code, let error): print("error: unsuccessful status code: \(code), error: \(error?.localizedDescription ?? "no error")")
            case .streamParsingFailure: print("error: stream parsing failure")
            }
        } catch let error as OpenAI.ChatCompletionError {
            switch error {
            case .failedToDecodeFunctionArguments: print("error: failed to decode function args")
            case .missingRequiredFunctionArguments: print("error: missing args")
            }
        } catch {
            throw error
        }
    }

    func getChatCompletion(for message: String, stream: Bool) async throws {
        await MainActor.run {
            messages.append(Message(text: message, role: .user))
        }
//        var id: UUID?
//        var content = ""

        let toolChoice = (tools?.isEmpty ?? true) ? nil : OpenAI.ChatCompletionRequest.ToolChoice.auto

        for try await message in try networkClient.streamChatCompletionRequest(messages: messages, stream: stream, tools: tools, toolChoice: toolChoice) {

            if let last = messages.last, last.uuid == message.uuid {
                await MainActor.run {
                    messages[self.messages.endIndex - 1] = message
                }
            } else {
                await MainActor.run {
                    messages.append(message)
                }
            }

            // handle non-streamed messages
//            if let message = response.choices.first?.message {
//                print("message received: \(message)")
//                if case .string(let text) = message.content {
//                    await MainActor.run {
//                        messages.append(Message(text: text, role: .assistant))
//                    }
//                }
//            }

            // handle stream messages
//            if let delta = response.choices.first?.delta {
//                if id == nil {
//                    let message = Message(text: "", role: .assistant)
//                    id = message.uuid
//                    await MainActor.run {
//                        messages.append(message)
//                    }
//                }
//                if let chunk = delta.content {
//                    print("received message delta: \(content)")
//                    content += chunk
//                    await MainActor.run { [content] in
//                        if let last = self.messages.last {
//                            messages[self.messages.endIndex - 1] = Message(uuid: last.uuid, text: content, role: .assistant)
//                        }
//                    }
//                }
//            }

            // handle finish reason
//            if let finishReason = response.choices.first?.finish_reason {
//                switch finishReason {
//                case .stop:
//                    guard !content.isEmpty else { break }
//                    print("message received: \(content)")
//                case .tool_calls, .length, .content_filter: break
//                }
//                id = nil
//            }

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
