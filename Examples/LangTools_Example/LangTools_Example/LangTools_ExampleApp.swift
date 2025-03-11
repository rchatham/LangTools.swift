//
//  LangTools_ExampleApp.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 9/23/24.
//

import SwiftUI
import LangTools
import OpenAI
import Anthropic
import Gemini
import XAI
import ChatUI

@main
struct LangTools_ExampleApp: App {
    var messageService = MessageService()
    var body: some Scene {
        WindowGroup {
            ChatView(title: "LangTools.swift", messageService: messageService, settingsView: chatSettingsView)
        }
    }

    @ViewBuilder
    func chatSettingsView() -> some View {
        ChatSettingsView(viewModel: ChatSettingsView.ViewModel(clearMessages: messageService.clearMessages))
    }
}

extension MessageService: ChatMessageService {
    var chatMessages: [Message] {
        get { messages }
        set { messages = newValue }
    }

    typealias ChatMessage = Message

    func handleError(error: any Error) -> ChatAlertInfo? {
        switch error {
        case let error as LangToolError:
            switch error {
            case .jsonParsingFailure(let error):
                return ChatAlertInfo(
                    title: "JSON Parsing Error",
                    message: error.localizedDescription
                )

            case .apiError(let error):
                return handleApiError(error)

            case .invalidData:
                return ChatAlertInfo(
                    title: "Invalid Data",
                    message: "The received data was invalid or corrupted."
                )

            case .invalidURL:
                return ChatAlertInfo(
                    title: "Invalid URL",
                    message: "The request URL was invalid."
                )

            case .requestFailed:
                return ChatAlertInfo(
                    title: "Request Failed",
                    message: "The network request failed to complete."
                )

            case .responseUnsuccessful(statusCode: let code, let error):
                var message = "Status code: \(code)"
                if let error {
                    message += "\nerror: " + (handleApiError(error)?.message ?? error.localizedDescription)
                }
                return ChatAlertInfo(
                    title: "Request Unsuccessful",
                    message: message
                )

            case .streamParsingFailure:
                return ChatAlertInfo(
                    title: "Stream Error",
                    message: "Failed to parse the response stream."
                )

            case .failiedToDecodeStream(buffer: let buffer, error: let error):
                return ChatAlertInfo(
                    title: "Stream Decoding Error",
                    message: "Failed to decode stream data: \(buffer).\n\(error.localizedDescription)"
                )

            case .invalidContentType:
                return ChatAlertInfo(
                    title: "Invalid Content",
                    message: "The response contained an invalid content type."
                )
            }

        case let error as LangToolsRequestError:
            switch error {
            case .multipleChoiceIndexOutOfBounds:
                return ChatAlertInfo(
                    title: "Invalid Selection",
                    message: "The selected choice was out of bounds."
                )

            case .failedToDecodeFunctionArguments:
                return ChatAlertInfo(
                    title: "Decoding Error",
                    message: "Failed to decode function arguments."
                )

            case .missingRequiredFunctionArguments:
                return ChatAlertInfo(
                    title: "Missing Arguments",
                    message: "Required function arguments are missing."
                )
            }

        case is LangToolchainError:
            let (serviceName, service): (String, APIService) = {
                switch UserDefaults.model {
                case .anthropic(_): return ("Anthropic", .anthropic)
                case .openAI(_): return ("OpenAI", .openAI)
                case .xAI(_): return ("xAI", .xAI)
                case .gemini(_): return ("Gemini", .gemini)
                case .ollama(_): return ("Ollama", .ollama)
                }
            }()

            let textBinding = Binding(
                get: { self.apiKeyInput },
                set: { self.apiKeyInput = $0 }
            )

            return ChatAlertInfo(
                title: "Enter API Key",
                textField: TextFieldInfo(
                    placeholder: "Enter your API key",
                    label: "API Key",
                    text: textBinding
                ),
                button: ButtonInfo(
                    text: "Save for \(serviceName)",
                    action: { [weak self] alertInfo in
                        let apiKey = textBinding.wrappedValue
                        try self?.networkClient.updateApiKey(apiKey, for: service)
                    }
                ),
                message: "Please enter your \(serviceName) API key."
            )

        default:
            return nil // ChatAlertInfo( title: "Unknown Error", message: "An unexpected error occurred." )
        }
    }

    func handleApiError(_ error: Error) -> ChatAlertInfo? {
        switch error {
        case let error as OpenAIErrorResponse:
            return ChatAlertInfo(
                title: "OpenAI API Error",
                button: ButtonInfo(
                    text: "OK",
                    role: .cancel
                ),
                message: error.error.message
            )

        case let error as XAIErrorResponse:
            return ChatAlertInfo(
                title: "xAI API Error",
                button: ButtonInfo(
                    text: "OK",
                    role: .cancel
                ),
                message: error.error.message
            )

        case let error as GeminiErrorResponse:
            return ChatAlertInfo(
                title: "Gemini API Error",
                button: ButtonInfo(
                    text: "OK",
                    role: .cancel
                ),
                message: error.error.message
            )

        case let error as AnthropicErrorResponse:
            return ChatAlertInfo(
                title: "Anthropic API Error",
                button: ButtonInfo(
                    text: "OK",
                    role: .cancel
                ),
                message: error.error.message
            )

        case let error as OllamaErrorResponse:
            return ChatAlertInfo(
                title: "Ollama API Error",
                button: ButtonInfo(
                    text: "OK",
                    role: .cancel
                ),
                message: error.error.message
            )

        default:
            return ChatAlertInfo(
                title: "API Error",
                button: ButtonInfo(
                    text: "OK",
                    role: .cancel
                ),
                message: "An unexpected API error occurred.\n\(error.localizedDescription)"
            )
        }
    }
}

extension Message: ChatMessageInfo {
    var parentMessage: Message? { parent }
    var childChatMessages: [Message] { childMessages }
}
