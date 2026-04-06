//
//  LangTools_ExampleApp.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 9/23/24.
//

import SwiftUI
import Chat
import Audio
import ExampleAgents

import LangTools
import Agents
import OpenAI
import Anthropic
import Gemini
import XAI
import Ollama
import ChatUI
import ToolKit

@main
struct LangTools_ExampleApp: App {
    // Use @StateObject so SwiftUI observes voiceInputHandler.objectWillChange
    // This enables instant UI updates when settings change
    @StateObject private var voiceInputHandler = VoiceInputHandlerAdapter()

    init() {
        registerToolConfigurations()
        initializeOllama()
    }

    var body: some Scene {
        WindowGroup {
            // Each window gets its own ChatContainerView with independent MessageService
            ChatContainerView(voiceInputHandler: voiceInputHandler)
        }
    }

    // @MainActor is required because ToolManager is @MainActor-isolated.
    // This is safe to call from App.init() since SwiftUI runs @main struct
    // initializers on the main actor.
    @MainActor
    func registerToolConfigurations() {
        ToolManager.shared.register([
            ToolConfiguration(
                id: "calendarAgent",
                displayName: "Calendar",
                description: "Read and manage calendar events",
                iconName: "calendar",
                isAgent: true
            ),
            ToolConfiguration(
                id: "reminderAgent",
                displayName: "Reminders",
                description: "Read and manage reminders",
                iconName: "checklist",
                isAgent: true
            ),
            ToolConfiguration(
                id: "researchAgent",
                displayName: "Research",
                description: "Search the web and scrape pages",
                iconName: "magnifyingglass",
                isAgent: true
            ),
        ])
    }

    func initializeOllama() {
        // Initialize OllamaService to start background refresh
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // Wait 1 second after app launch
            await MainActor.run {
                OllamaService.shared.refreshModels()
            }
        }
    }
}

/// Per-window container that holds the MessageService @StateObject
/// Each window creates a new instance, giving each window independent chat state
struct ChatContainerView: View {
    @StateObject private var messageService: MessageService
    @ObservedObject var voiceInputHandler: VoiceInputHandlerAdapter

    init(voiceInputHandler: VoiceInputHandlerAdapter) {
        let agents: [Agent] = [
            CalendarAgent(),
            ReminderAgent(),
            ResearchAgent()
        ]
        let service = MessageService(agents: agents)
        service.agentResultParser = makeAgentResultParser()
        _messageService = StateObject(wrappedValue: service)
        self.voiceInputHandler = voiceInputHandler
    }

    var body: some View {
        NavigationStack {
            ChatView<MessageService>(
                title: "LangTools.swift",
                messageService: messageService,
                settingsView: { chatSettingsView },
                voiceInputHandler: voiceInputHandler
            ) { message in
                messageContentView(for: message)
            }
        }
    }

    /// Custom view builder for message content — handles structured card types.
    @ViewBuilder
    private func messageContentView(for message: Message) -> some View {
        if case .contentCards(let content) = message.contentType {
            contentCardsView(content: content)
                .padding(.horizontal, 4)
        } else {
            // Default rendering — delegate to ChatUI's standard text bubble.
            defaultMessageBubble(for: message)
        }
    }

    /// Dispatch to the right card view based on `cardType`.
    @ViewBuilder
    private func contentCardsView(content: ContentCardsContent) -> some View {
        switch content.cardType {
        case "calendarEvent":
            CalendarEventCardListView(content: content)
        default:
            // Fallback: show the raw JSON summary
            Text(content.message ?? content.cardType)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(10)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Reproduces ChatUI's default bubble appearance for non-card messages.
    @ViewBuilder
    private func defaultMessageBubble(for message: Message) -> some View {
        Text(message.text ?? "")
            .font(.system(size: 16))
            .foregroundColor(message.isUser ? .primary : .white)
            .padding(10)
            .background(message.isUser ? Color.gray.opacity(0.2) : Color.blue)
            .cornerRadius(10)
    }

    private var chatSettingsView: AnyView {
        let viewModel = ChatSettingsView.ViewModel(clearMessages: messageService.clearMessages)

        // Wire up WhisperKit state from voice input handler
        viewModel.onPreloadWhisperKit = { [weak voiceInputHandler] in
            voiceInputHandler?.preloadWhisperKit()
        }
        viewModel.getWhisperKitState = { [weak voiceInputHandler] in
            guard let handler = voiceInputHandler else {
                return (isLoading: false, description: "Not available")
            }
            return (
                isLoading: handler.whisperKitLoadingState.isLoading,
                description: handler.whisperKitLoadingState.description
            )
        }

        return AnyView(ChatSettingsView(viewModel: viewModel))
    }
}

extension MessageService: @retroactive ChatMessageService {
    public var chatMessages: [Message] {
        get { messages }
        set { messages = newValue }
    }

    public typealias ChatMessage = Message

    public func handleError(error: any Error) -> ChatAlertInfo? {
        switch error {
        case let error as LangToolsError:
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

            case .failedToDecodeStream(buffer: let buffer, error: let error):
                return ChatAlertInfo(
                    title: "Stream Decoding Error",
                    message: "Failed to decode stream data: \(buffer).\n\(error.localizedDescription)"
                )

            case .invalidContentType:
                return ChatAlertInfo(
                    title: "Invalid Content",
                    message: "The response contained an invalid content type."
                )

            default: return nil
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
                get: { apiKeyInput },
                set: { apiKeyInput = $0 }
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

extension Message: @retroactive ChatMessageInfo {
    public weak var parentMessage: Message? { parent }
    public var childChatMessages: [Message] { childMessages }
}

// local variable used to store apiKey while passing from ui to app
private var apiKeyInput: String = ""
