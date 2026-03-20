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

    /// All registered tools wired to ToolRegistry for execution
    var tools: [OpenAI.Tool]? {
        let registryTools = ToolRegistry.shared.asOpenAITools()
        return registryTools.isEmpty ? nil : registryTools
    }

    func performMessageCompletionRequest(message: String, stream: Bool = false, silent: Bool = false) async throws {
        do {
            try await getChatCompletion(for: message, stream: stream, silent: silent)
        } catch let error as LangToolsError {
            handleLangToolsError(error)
        } catch let error as LangToolsRequestError {
            handleLangToolsRequestError(error)
        } catch {
            print("Unexpected error: \(error.localizedDescription)")
            throw error
        }
    }

    func getChatCompletion(for message: String, stream: Bool, silent: Bool = false) async throws {
        await MainActor.run {
            messages.append(Message(text: message, role: .user))
        }

        let toolChoice = (tools?.isEmpty ?? true) ? nil : OpenAI.ChatCompletionRequest.ToolChoice.auto
        if !silent {
            print("\rAssistant: ".yellow, terminator: "")
        }
        let uuid = UUID(); var content: String = ""
        let stream = try streamChatCompletionRequest(
            messages: messages,
            stream: stream,
            tools: tools,
            toolChoice: toolChoice
        )
        for try await chunk in stream {
            if !silent {
                // hack to print new lines as long as they aren't the last one
                if content.hasSuffix("\n") {
                    print("")
                }

                await MainActor.run {
                    print("\(chunk.trimingTrailingNewlines())", terminator: "")
                }
                fflush(stdout)
            }

            content += chunk
            let message = Message(uuid: uuid, text: content.trimingTrailingNewlines(), role: .assistant)

            if let last = messages.last, last.uuid == uuid {
                messages[messages.endIndex - 1] = message
            } else {
                messages.append(message)
            }
        }

        if !silent {
            print("") // Add a newline after the complete response
        }
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

    /// Clear all messages from the conversation history
    func clearMessages() {
        messages.removeAll()
    }
}
