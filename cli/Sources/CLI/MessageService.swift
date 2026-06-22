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
    final class ToolCallTrace {
        var calledToolNames: [String] = []
        var completionResults: [String] = []
        var errorResults: [String] = []

        var sawToolCall: Bool {
            !calledToolNames.isEmpty
        }
    }

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

        let model = UserDefaults.model
        let toolChoice = (tools?.isEmpty ?? true) ? nil : OpenAI.ChatCompletionRequest.ToolChoice.auto
        let toolTrace = ToolCallTrace()
        if !silent {
            print("\rAssistant: ".yellow, terminator: "")
        }
        let uuid = UUID(); var content: String = ""
        let stream = try streamChatCompletionRequest(
            messages: messages,
            model: model,
            stream: stream,
            tools: tools,
            toolChoice: toolChoice,
            toolTrace: toolTrace
        )
        for try await chunk in stream {
            if !silent {
                if content.hasSuffix("\n") {
                    print("")
                }

                await MainActor.run {
                    print("\(chunk.trimingTrailingNewlines())", terminator: "")
                }
                fflush(stdout)
            }

            content += chunk
            upsertAssistantMessage(id: uuid, text: content.trimingTrailingNewlines())
        }

        let finalContent = resolvedAssistantContent(content: content, toolTrace: toolTrace, model: model)
        if finalContent != content.trimingTrailingNewlines() {
            if !silent, !finalContent.isEmpty {
                if !content.isEmpty {
                    print("")
                }
                print(finalContent, terminator: "")
            }
            upsertAssistantMessage(id: uuid, text: finalContent)
        }

        if !silent {
            print("")
        }
    }

    func streamChatCompletionRequest(
        messages: [Message],
        model: Model = UserDefaults.model,
        stream: Bool = true,
        tools: [OpenAI.Tool]? = nil,
        toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil,
        toolTrace: ToolCallTrace? = nil
    ) throws -> AsyncThrowingStream<String, Error> {
        let request = networkClient.request(
            messages: messages,
            model: model,
            stream: stream,
            tools: tools,
            toolChoice: toolChoice,
            toolEventHandler: makeToolEventHandler(for: toolTrace)
        )
        return try langToolchain.stream(request: request).compactMapAsyncThrowingStream { $0.content?.text }
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
            print("The model emitted malformed tool arguments.")
        case .missingRequiredFunctionArguments:
            print("The model omitted required tool arguments.")
        }
    }

    func makeToolEventHandler(for toolTrace: ToolCallTrace?) -> (LangToolsToolEvent) -> Void {
        guard let toolTrace else {
            return { _ in }
        }

        return { event in
            switch event {
            case .toolCalled(let toolSelection):
                if let name = toolSelection.name {
                    toolTrace.calledToolNames.append(name)
                }
            case .toolCompleted(let toolResult):
                guard let toolResult else { return }
                if toolResult.is_error {
                    toolTrace.errorResults.append(toolResult.result)
                } else {
                    toolTrace.completionResults.append(toolResult.result)
                }
            }
        }
    }

    func resolvedAssistantContent(content: String, toolTrace: ToolCallTrace, model: Model) -> String {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedContent.isEmpty else {
            return content.trimingTrailingNewlines()
        }

        if let fallback = fallbackMessageForEmptyAssistantResponse(toolTrace: toolTrace, model: model) {
            return fallback
        }

        return content.trimingTrailingNewlines()
    }

    func fallbackMessageForEmptyAssistantResponse(toolTrace: ToolCallTrace, model: Model) -> String? {
        if let unknownTool = toolTrace.calledToolNames.first(where: { ToolRegistry.shared.tool(named: $0) == nil }) {
            return "The model requested unsupported tool '\(unknownTool)'. Try rephrasing or switching models."
        }

        if let malformedArguments = toolTrace.errorResults.first(where: {
            $0.localizedCaseInsensitiveContains("Failed to decode function arguments") ||
            $0.localizedCaseInsensitiveContains("Missing required function arguments") ||
            $0.localizedCaseInsensitiveContains("Invalid parameters")
        }) {
            return "The model emitted malformed tool arguments. \(malformedArguments)"
        }

        if let toolFailure = toolTrace.errorResults.first {
            return "A tool call failed before the assistant produced a response. \(toolFailure)"
        }

        if toolTrace.sawToolCall {
            if model.capabilities.toolReliability == .limited {
                return "The model attempted a tool call but did not produce a usable reply. Local/Ollama models may be unreliable for tool-heavy tasks."
            }
            return "The assistant did not return a usable reply after tool handling. Try again."
        }

        return nil
    }

    private func upsertAssistantMessage(id: UUID, text: String) {
        let message = Message(uuid: id, text: text, role: .assistant)

        if let last = messages.last, last.uuid == id {
            messages[messages.endIndex - 1] = message
        } else {
            messages.append(message)
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
