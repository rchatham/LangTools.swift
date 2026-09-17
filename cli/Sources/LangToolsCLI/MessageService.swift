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
import Combine

class MessageService: ObservableObject {
    struct ToolAvailabilityDecision {
        let tools: [OpenAI.Tool]?
        let toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?
        let warning: String?
    }

    struct ToolDisplayEvent: Equatable {
        enum Kind: Equatable {
            case call
            case result(isError: Bool)
        }

        let kind: Kind
        let toolName: String
        let detail: String
        let selectionID: String?
    }

    final class ToolCallTrace {
        struct ToolEventRecord {
            let kind: Kind
            let name: String?
            let message: String?

            enum Kind {
                case called
                case completed
                case failed
            }
        }

        var calledToolNames: [String] = []
        var completionResults: [String] = []
        var errorResults: [String] = []
        var events: [ToolEventRecord] = []
        var displayEvents: [ToolDisplayEvent] = []
        var toolNamesByID: [String: String] = [:]

        var sawToolCall: Bool {
            !calledToolNames.isEmpty
        }
    }

    var messages: [Message] = []
    private(set) var toolDisplayEvents: [ToolDisplayEvent] = []
    private var emittedToolWarnings: Set<String> = []

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
        } catch let error as LangToolchainError {
            handleLangToolchainError(error)
        } catch {
            print("Unexpected error: \(error.localizedDescription)")
            throw error
        }
    }

    func getChatCompletion(for message: String, stream: Bool, silent: Bool = false) async throws {
        await MainActor.run {
            if !messages.contains(where: { $0.role == .system }) {
                messages.append(Self.contextSystemMessage(cwd: FileManager.default.currentDirectoryPath))
            }
            messages.append(Message(text: message, role: .user))
        }

        let model = UserDefaults.model
        let requestedToolChoice = (tools?.isEmpty ?? true) ? nil : OpenAI.ChatCompletionRequest.ToolChoice.auto
        let toolDecision = toolAvailabilityDecision(for: model, tools: tools, toolChoice: requestedToolChoice)
        emitToolWarningIfNeeded(toolDecision.warning, model: model, silent: silent)
        let toolTrace = ToolCallTrace()
        let uuid = UUID(); var content: String = ""
        var didRenderAssistantPrefix = false
        var didRenderAssistantContent = false
        let stream = try streamChatCompletionRequest(
            messages: messages,
            model: model,
            stream: stream,
            tools: toolDecision.tools,
            toolChoice: toolDecision.toolChoice,
            toolTrace: toolTrace,
            silent: silent
        )
        for try await chunk in stream {
            if let displayableChunk = displayableAssistantChunk(from: chunk) {
                if !silent {
                    renderAssistantPrefixIfNeeded(rendered: &didRenderAssistantPrefix)
                    if didRenderAssistantContent, content.hasSuffix("\n") {
                        print("")
                    }

                    await MainActor.run {
                        print(displayableChunk, terminator: "")
                    }
                    fflush(stdout)
                }
                didRenderAssistantContent = true
            }

            content += chunk
            upsertAssistantMessage(id: uuid, text: content.trimingTrailingNewlines())
        }

        if silent {
            toolDisplayEvents.append(contentsOf: Self.hierarchicalToolEvents(toolTrace.displayEvents))
            if let toolSummary = toolEventSummaryMessage(toolTrace: toolTrace, model: model) {
                messages.append(Message(text: toolSummary, role: .system))
            }
        }

        let finalContent = resolvedAssistantContent(content: content, toolTrace: toolTrace, model: model)
        if finalContent != content.trimingTrailingNewlines() {
            if !silent, !finalContent.isEmpty {
                renderAssistantPrefixIfNeeded(rendered: &didRenderAssistantPrefix)
                if didRenderAssistantContent {
                    print("")
                }
                print(finalContent, terminator: "")
                didRenderAssistantContent = true
            }
            upsertAssistantMessage(id: uuid, text: finalContent)
        }

        if !silent, didRenderAssistantPrefix {
            print("")
        }
    }

    func streamChatCompletionRequest(
        messages: [Message],
        model: Model = UserDefaults.model,
        stream: Bool = true,
        tools: [OpenAI.Tool]? = nil,
        toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil,
        toolTrace: ToolCallTrace? = nil,
        silent: Bool = false
    ) throws -> AsyncThrowingStream<String, Error> {
        let request = networkClient.request(
            messages: messages,
            model: model,
            stream: stream,
            tools: tools,
            toolChoice: toolChoice,
            toolEventHandler: makeToolEventHandler(for: toolTrace, silent: silent)
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
            print("Failed to parse the streaming response.")
        case .failedToDecodeStream:
            print("Failed to decode the streaming response. Try again or switch models.")
        case .invalidContentType:
            print("Invalid content type")
        default: break
        }
    }

    func handleLangToolchainError(_ error: LangToolchainError) {
        switch error {
        case .toolchainCannotHandleRequest:
            for line in missingProviderMessageLines(for: UserDefaults.model) {
                print(line)
            }
        }
    }

    func missingProviderMessageLines(for model: Model) -> [String] {
        let provider = model.provider
        let envVar: String
        let serviceName: String

        switch provider {
        case .openAI:
            envVar = "OPENAI_API_KEY"
            serviceName = "OpenAI"
        case .anthropic:
            envVar = "ANTHROPIC_API_KEY"
            serviceName = "Anthropic"
        case .xAI:
            envVar = "XAI_API_KEY"
            serviceName = "xAI"
        case .gemini:
            envVar = "GEMINI_API_KEY"
            serviceName = "Gemini"
        case .ollama:
            return ["The current Ollama model could not be reached. Check that Ollama is running and the model is available."]
        }

        return [
            "No configured provider could handle the current model '\(model.rawValue)'.",
            "Set a \(serviceName) API key with /apikey or export \(envVar), then try again.",
            "Use /status to inspect configuration or /model to switch models."
        ]
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

    func toolAvailabilityDecision(
        for model: Model,
        tools: [OpenAI.Tool]?,
        toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?
    ) -> ToolAvailabilityDecision {
        guard let tools, !tools.isEmpty else {
            return ToolAvailabilityDecision(tools: nil, toolChoice: nil, warning: nil)
        }

        let capabilities = model.capabilities
        switch capabilities.toolReliability {
        case .recommended:
            return ToolAvailabilityDecision(tools: tools, toolChoice: toolChoice, warning: nil)
        case .limited:
            return ToolAvailabilityDecision(tools: tools, toolChoice: toolChoice, warning: capabilities.toolWarningText)
        case .unavailable:
            return ToolAvailabilityDecision(tools: nil, toolChoice: nil, warning: capabilities.toolWarningText)
        }
    }

    func emitToolWarningIfNeeded(_ warning: String?, model: Model, silent: Bool) {
        guard let warning else { return }

        let warningKey = "\(model.rawValue)::\(warning)"
        guard emittedToolWarnings.insert(warningKey).inserted else { return }

        if silent {
            messages.append(Message(text: warning, role: .system))
        } else {
            print(warning.yellow)
        }
    }

    func makeToolEventHandler(for toolTrace: ToolCallTrace?, silent: Bool = false) -> (LangToolsToolEvent) -> Void {
        guard let toolTrace else {
            return { _ in }
        }

        return { event in
            switch event {
            case .toolCalled(let toolSelection):
                if let name = toolSelection.name {
                    toolTrace.calledToolNames.append(name)
                    toolTrace.events.append(.init(kind: .called, name: name, message: nil))
                    if let id = toolSelection.id {
                        toolTrace.toolNamesByID[id] = name
                    }
                    toolTrace.displayEvents.append(.init(
                        kind: .call,
                        toolName: name,
                        detail: toolSelection.arguments,
                        selectionID: toolSelection.id
                    ))
                    if !silent {
                        self.printToolEventLine(.call, toolName: name, detail: toolSelection.arguments)
                    }
                }
            case .toolCompleted(let toolResult):
                guard let toolResult else { return }
                let toolName = toolTrace.toolNamesByID[toolResult.tool_selection_id] ?? "Tool"
                if toolResult.is_error {
                    toolTrace.errorResults.append(toolResult.result)
                    toolTrace.events.append(.init(kind: .failed, name: toolName, message: toolResult.result))
                } else {
                    toolTrace.completionResults.append(toolResult.result)
                    toolTrace.events.append(.init(kind: .completed, name: toolName, message: toolResult.result))
                }
                toolTrace.displayEvents.append(.init(
                    kind: .result(isError: toolResult.is_error),
                    toolName: toolName,
                    detail: toolResult.result,
                    selectionID: toolResult.tool_selection_id
                ))
                if !silent {
                    self.printToolEventLine(.result(isError: toolResult.is_error), toolName: toolName, detail: toolResult.result)
                }
            }
        }
    }

    /// Print a compact tool call/result line to the terminal for the standard
    /// (non-TUI) CLI, mirroring the TUI's compact hierarchy. Bounded previews
    /// keep verbose tool output from flooding the terminal.
    private func printToolEventLine(_ kind: MessageService.ToolDisplayEvent.Kind, toolName: String, detail: String) {
        let isResult: Bool
        let isError: Bool
        switch kind {
        case .call: isResult = false; isError = false
        case .result(let err): isResult = true; isError = err
        }
        let prefix: String
        let headerColor: ANSIColor
        if isResult {
            prefix = isError ? "  ✗ Result" : "  ✓ Result"
            headerColor = isError ? .red : .magenta
        } else {
            prefix = "↳ Call"
            headerColor = .magenta
        }
        print("")
        let header = "\(prefix) \(toolName)"
        print(header.colored(headerColor))
        let lines = MessageLineBuilder.toolPreviewLines(content: detail, isResult: isResult)
        for line in lines {
            print("  \(line)")
        }
    }

    /// Grounding context so the model resolves project-relative paths against
    /// the real working directory instead of guessing absolute paths.
    static func contextSystemMessage(cwd: String) -> Message {
        Message(
            text: """
            You are the assistant embedded in the LangTools CLI, a terminal chat application.
            The user's current working directory is: \(cwd)
            When using file tools, resolve project-relative paths against this directory.
            """,
            role: .system
        )
    }

    func resolvedAssistantContent(content: String, toolTrace: ToolCallTrace, model: Model) -> String {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            if let fallback = fallbackMessageForEmptyAssistantResponse(toolTrace: toolTrace, model: model) {
                return fallback
            }
            return content.trimingTrailingNewlines()
        }

        if looksLikeSerializedToolCallArtifact(trimmedContent) {
            return fallbackMessageForSerializedToolArtifact(model: model)
        }

        return content.trimingTrailingNewlines()
    }

    func toolEventSummaryMessage(toolTrace: ToolCallTrace, model: Model) -> String? {
        if let unknownTool = toolTrace.calledToolNames.first(where: { ToolRegistry.shared.tool(named: $0) == nil }) {
            return "Tool warning: model requested unsupported tool '\(unknownTool)'."
        }

        if toolTrace.errorResults.contains(where: isMalformedToolArgumentError(_:)) {
            return "Tool error: model emitted malformed tool arguments."
        }

        if let toolFailure = toolTrace.errorResults.first {
            return formatToolFailureLine(toolFailure)
        }

        if toolTrace.sawToolCall {
            if model.capabilities.toolReliability == .limited {
                return "Warning: model attempted a tool call but produced no usable reply."
            }
            return "Warning: assistant produced no usable reply after tool handling."
        }

        return nil
    }

    func fallbackMessageForEmptyAssistantResponse(toolTrace: ToolCallTrace, model: Model) -> String? {
        if let unknownTool = toolTrace.calledToolNames.first(where: { ToolRegistry.shared.tool(named: $0) == nil }) {
            return "The model requested unsupported tool '\(unknownTool)'. Try rephrasing or switching models."
        }

        if toolTrace.errorResults.contains(where: isMalformedToolArgumentError(_:)) {
            return "The model emitted malformed tool arguments. Try again or switch models."
        }

        if let toolFailure = toolTrace.errorResults.first {
            return "\(formatToolFailureLine(toolFailure)) Try again if the task still needs that tool."
        }

        if toolTrace.sawToolCall {
            if model.capabilities.toolReliability == .limited {
                return "The model attempted a tool call but did not produce a usable reply. Local/Ollama models may be unreliable for tool-heavy tasks."
            }
            return "The assistant did not return a usable reply after tool handling. Try again."
        }

        return nil
    }

    func fallbackMessageForSerializedToolArtifact(model: Model) -> String {
        if model.capabilities.toolReliability == .limited {
            return "The model produced an unusable tool-call artifact instead of a normal reply. Local/Ollama models may be unreliable for tool-heavy tasks."
        }
        return "The model produced an unusable tool-call artifact instead of a normal reply. Try again or switch models."
    }

    func looksLikeSerializedToolCallArtifact(_ content: String) -> Bool {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("{"), normalized.hasSuffix("}") else { return false }
        guard normalized.localizedCaseInsensitiveContains("\"name\"") else { return false }
        return normalized.localizedCaseInsensitiveContains("\"parameters\"") || normalized.localizedCaseInsensitiveContains("\"arguments\"")
    }

    func displayableAssistantChunk(from chunk: String) -> String? {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return chunk.trimingTrailingNewlines()
    }

    func formatToolFailureLine(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Tool error: The tool failed before the assistant produced a response." }
        return "Tool error: \(trimmed)"
    }

    func isMalformedToolArgumentError(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("Failed to decode function arguments") ||
        message.localizedCaseInsensitiveContains("Missing required function arguments") ||
        message.localizedCaseInsensitiveContains("Invalid parameters")
    }

    private func renderAssistantPrefixIfNeeded(rendered: inout Bool) {
        guard !rendered else { return }
        print("\rAssistant: ".yellow, terminator: "")
        rendered = true
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

    static func hierarchicalToolEvents(_ events: [ToolDisplayEvent]) -> [ToolDisplayEvent] {
        let calls = events.filter {
            if case .call = $0.kind { return true }
            return false
        }
        let results = events.filter {
            if case .result = $0.kind { return true }
            return false
        }

        var consumedResultIndexes = Set<Int>()
        var ordered: [ToolDisplayEvent] = []
        for call in calls {
            ordered.append(call)
            if let selectionID = call.selectionID,
               let resultIndex = results.indices.first(where: {
                   !consumedResultIndexes.contains($0) && results[$0].selectionID == selectionID
               }) {
                ordered.append(results[resultIndex])
                consumedResultIndexes.insert(resultIndex)
            }
        }
        ordered.append(contentsOf: results.indices.compactMap {
            consumedResultIndexes.contains($0) ? nil : results[$0]
        })
        return ordered
    }

    /// Clear all messages from the conversation history
    func clearMessages() {
        messages.removeAll()
        toolDisplayEvents.removeAll()
    }
}
