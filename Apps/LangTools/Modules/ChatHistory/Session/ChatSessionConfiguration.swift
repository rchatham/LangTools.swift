//
//  ChatSessionConfiguration.swift
//  ChatHistory
//
//  The host-supplied pieces a `ChatSession` is built from. A host app keeps
//  its provider routing, agents, error mapping and settings policy here, so
//  the persistence pipeline itself stays generic.
//

import Foundation
import Agents
import Chat
import ChatUI
import LangTools
import ToolKit

/// What a hook knows about the conversation a session belongs to.
@MainActor
public struct ChatSessionContext {
    public let conversationID: UUID
    private let recordProvider: @MainActor () -> ConversationRecord?

    init(conversationID: UUID, recordProvider: @escaping @MainActor () -> ConversationRecord?) {
        self.conversationID = conversationID
        self.recordProvider = recordProvider
    }

    /// The conversation's current record, read at call time so settings
    /// changed after the session was created still apply. For a draft that
    /// has not been saved yet this is the draft's provisional record.
    public var record: ConversationRecord? { recordProvider() }
}

/// Resolves the model and conversation settings for one request.
@MainActor
public protocol ChatSettingsResolving {
    func model(for conversation: ConversationRecord?) -> Model
    func conversationSettings(for conversation: ConversationRecord?) -> ChatConversationSettings
}

/// Conversation overrides first, then the global chat settings.
@MainActor
public struct DefaultChatSettingsResolver: ChatSettingsResolving {
    public var globalModel: @MainActor () -> Model
    public var globalSettings: @MainActor () -> ChatConversationSettings
    /// Called when a stored model identifier no longer resolves (for example
    /// after a provider renames a model); the global model is used instead.
    public var onUnresolvedModel: (@MainActor (String) -> Void)?

    public init(
        globalModel: @escaping @MainActor () -> Model = { UserDefaults.model },
        globalSettings: @escaping @MainActor () -> ChatConversationSettings = { ChatConversationSettingsStore().load() },
        onUnresolvedModel: (@MainActor (String) -> Void)? = nil
    ) {
        self.globalModel = globalModel
        self.globalSettings = globalSettings
        self.onUnresolvedModel = onUnresolvedModel
    }

    public func model(for conversation: ConversationRecord?) -> Model {
        guard let identifier = conversation?.settings.modelIdentifier, !identifier.isEmpty else {
            return globalModel()
        }
        if let model = Model(rawValue: identifier) { return model }
        onUnresolvedModel?(identifier)
        return globalModel()
    }

    public func conversationSettings(for conversation: ConversationRecord?) -> ChatConversationSettings {
        Self.merge(globalSettings(), overrides: conversation?.settings ?? .none)
    }

    /// Applies non-nil overrides on top of `base`. Memory fields always come
    /// from `base`; they are not a per-conversation setting.
    public static func merge(
        _ base: ChatConversationSettings,
        overrides: ConversationSettingsOverrides
    ) -> ChatConversationSettings {
        ChatConversationSettings(
            systemPrompt: overrides.systemPrompt ?? base.systemPrompt,
            maxContextMessages: overrides.maxContextMessages ?? base.maxContextMessages,
            contextWindowPercent: overrides.contextWindowPercent ?? base.contextWindowPercent,
            memoryFields: base.memoryFields
        )
    }
}

public enum ChatSessionError: LocalizedError, Equatable {
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .persistenceFailed(let description):
            return "The response could not be saved: \(description)"
        }
    }
}

/// Host behavior for every session a `ChatSessionManager` creates.
@MainActor
public struct ChatSessionHooks {
    /// Builds the `MessageService` for one conversation.
    public var makeMessageService: @MainActor (ChatSessionContext) -> MessageService
    /// Optional per-conversation request preparer (compaction, memory, ...).
    public var makeRequestPreparer: (@MainActor (ChatSessionContext) -> (@MainActor (ChatRequestContext) async throws -> ChatRequestContext)?)?
    /// Converts structured agent results into messages (content cards).
    public var agentResultParser: ((_ result: String, _ agentName: String) -> Message?)?
    /// Maps a send error before it is thrown to the UI.
    public var mapSendError: @MainActor (Error) -> Error
    /// Builds the alert for an error, or `nil` when the host handles it.
    public var alert: @MainActor (Error) -> ChatAlertInfo?
    /// When true, a prompt whose send failed before producing any output is
    /// removed, so ChatUI restores it to the composer instead of keeping a
    /// failed bubble. Botsworth relies on this.
    public var removesFailedPromptWithoutOutput: Bool

    public init(
        makeMessageService: @escaping @MainActor (ChatSessionContext) -> MessageService,
        makeRequestPreparer: (@MainActor (ChatSessionContext) -> (@MainActor (ChatRequestContext) async throws -> ChatRequestContext)?)? = nil,
        agentResultParser: ((_ result: String, _ agentName: String) -> Message?)? = nil,
        mapSendError: @escaping @MainActor (Error) -> Error = { $0 },
        alert: @escaping @MainActor (Error) -> ChatAlertInfo? = { ChatAlertInfo(title: "Error", message: $0.localizedDescription) },
        removesFailedPromptWithoutOutput: Bool = true
    ) {
        self.makeMessageService = makeMessageService
        self.makeRequestPreparer = makeRequestPreparer
        self.agentResultParser = agentResultParser
        self.mapSendError = mapSendError
        self.alert = alert
        self.removesFailedPromptWithoutOutput = removesFailedPromptWithoutOutput
    }

    /// Message services wired to the shared tool registry and settings, with
    /// model and prompt resolved per conversation by `resolver`.
    public static func standard(
        networkClient: NetworkClientProtocol,
        agents: [any Agent]? = nil,
        tools: [Tool]? = nil,
        resolver: (any ChatSettingsResolving)? = nil,
        toolSettings: ToolSettings = .shared
    ) -> ChatSessionHooks {
        let resolver = resolver ?? DefaultChatSettingsResolver()
        return ChatSessionHooks(makeMessageService: { context in
            MessageService(
                networkClient: networkClient,
                agents: agents,
                tools: tools,
                dependencies: MessageService.Dependencies(
                    selectedModel: { resolver.model(for: context.record) },
                    conversationSettings: { resolver.conversationSettings(for: context.record) },
                    keepsToolCallsInHistory: { toolSettings.keepsToolCallsInHistory },
                    maxToolIterations: { toolSettings.maxToolIterations },
                    enabledTools: { ToolManager.shared.filteredTools() },
                    toolConfigurations: { ToolManager.shared.allToolConfigurations() }
                )
            )
        })
    }
}

/// Persistence pacing. Streaming updates are grouped for `debounce` seconds
/// but saved at least every `maximumLatency` seconds; failed automatic saves
/// retry with exponential backoff up to `maximumAutomaticAttempts` times.
public struct ChatPersistenceTiming: Sendable {
    public var debounce: TimeInterval
    public var maximumLatency: TimeInterval
    public var maximumAutomaticAttempts: Int
    public var initialRetryDelay: TimeInterval
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public static let standard = ChatPersistenceTiming()

    public init(
        debounce: TimeInterval = 0.5,
        maximumLatency: TimeInterval = 2,
        maximumAutomaticAttempts: Int = 3,
        initialRetryDelay: TimeInterval = 0.5,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.debounce = debounce
        self.maximumLatency = maximumLatency
        self.maximumAutomaticAttempts = maximumAutomaticAttempts
        self.initialRetryDelay = initialRetryDelay
        self.sleep = sleep
    }
}
