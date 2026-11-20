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
import ChatContext
import ChatUI
import LangTools
import ToolKit

/// What a hook knows about the conversation a session belongs to.
@MainActor
public struct ChatSessionContext {
    public let conversationID: UUID
    /// Where this conversation's context checkpoints live: the session's store.
    public let checkpoints: any ContextCheckpointStore
    private let recordProvider: @MainActor () -> ConversationRecord?
    private let compactionRelay: ChatSessionCompactionRelay

    init(
        conversationID: UUID,
        checkpoints: any ContextCheckpointStore,
        compactionRelay: ChatSessionCompactionRelay,
        recordProvider: @escaping @MainActor () -> ConversationRecord?
    ) {
        self.conversationID = conversationID
        self.checkpoints = checkpoints
        self.compactionRelay = compactionRelay
        self.recordProvider = recordProvider
    }

    /// Passes compaction progress to the session, which publishes it for
    /// the UI (`ChatSession.isCompacting`, `ChatSession.checkpoints`).
    /// `compactingRequestPreparers` reports every event; a custom preparer
    /// that wraps a `CompactingRequestPreparer` should forward its events.
    public func reportCompaction(_ event: CompactingRequestPreparer.Event) {
        compactionRelay.handler?(event)
    }

    /// The conversation's current record, read at call time so settings
    /// changed after the session was created still apply. For a draft that
    /// has not been saved yet this is the draft's provisional record.
    public var record: ConversationRecord? { recordProvider() }
}

/// Carries compaction events from a session's request preparer to the
/// session, which exists only after its preparer is built.
@MainActor
final class ChatSessionCompactionRelay {
    var handler: ((CompactingRequestPreparer.Event) -> Void)?
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

/// What a session does with a prompt whose send failed before producing any
/// output. A failure with partial output always keeps and stores both.
public enum FailedPromptHandling: Sendable, Equatable {
    /// Remove the prompt, so ChatUI puts its text back in the composer and
    /// shows the error alert.
    case returnToComposer
    /// Keep the prompt on screen with ChatUI's inline failure and Retry row,
    /// and still report the error through `handleError`, so alerts, sign-in
    /// and API key prompts appear. The prompt stays out of storage until a
    /// retry delivers it.
    case keepWithRetry
    /// Keep the prompt and store it like any other message. ChatUI shows the
    /// failure inline only.
    case keepInline
}

/// A send or retry starting or finishing in one conversation.
public struct ChatSendEvent: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case succeeded
        case failed
        /// Stopped by the caller or by closing the session, including any
        /// error the cancellation caused.
        case cancelled
    }

    public enum Kind: Equatable, Sendable {
        case started
        case finished(Outcome)
    }

    public let conversationID: UUID
    public let kind: Kind
    /// Whether another send in the same conversation is still in flight.
    public let isStillSending: Bool

    public init(conversationID: UUID, kind: Kind, isStillSending: Bool) {
        self.conversationID = conversationID
        self.kind = kind
        self.isStillSending = isStillSending
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
    /// Builds the alert for an error, or `nil` when the host handles it. It
    /// gets the conversation's `MessageService`, which can answer provider
    /// errors (such as an API key prompt) for its own network client.
    public var alert: @MainActor (_ error: Error, _ messageService: MessageService) -> ChatAlertInfo?
    /// What happens to a prompt whose send failed before producing output.
    public var failedPromptHandling: FailedPromptHandling
    /// Reports sends and retries starting and finishing, for UI that reacts
    /// to pending replies. Persistence retries are not reported.
    public var onSendEvent: (@MainActor (ChatSendEvent) -> Void)?

    public init(
        makeMessageService: @escaping @MainActor (ChatSessionContext) -> MessageService,
        makeRequestPreparer: (@MainActor (ChatSessionContext) -> (@MainActor (ChatRequestContext) async throws -> ChatRequestContext)?)? = nil,
        agentResultParser: ((_ result: String, _ agentName: String) -> Message?)? = nil,
        mapSendError: @escaping @MainActor (Error) -> Error = { $0 },
        alert: @escaping @MainActor (_ error: Error, _ messageService: MessageService) -> ChatAlertInfo? = { error, _ in
            ChatAlertInfo(title: "Error", message: error.localizedDescription)
        },
        failedPromptHandling: FailedPromptHandling = .returnToComposer,
        onSendEvent: (@MainActor (ChatSendEvent) -> Void)? = nil
    ) {
        self.makeMessageService = makeMessageService
        self.makeRequestPreparer = makeRequestPreparer
        self.agentResultParser = agentResultParser
        self.mapSendError = mapSendError
        self.alert = alert
        self.failedPromptHandling = failedPromptHandling
        self.onSendEvent = onSendEvent
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

/// How much of a stored conversation a session loads when it opens.
///
/// A session always loads every message after the conversation's latest
/// context checkpoint, because requests replay them. Older messages, already
/// summarized, load on demand with `ChatSession.loadEarlierMessages()`.
/// Without a checkpoint every message is loaded, so requests never silently
/// lose history.
public struct ChatSessionPaging: Sendable, Equatable {
    /// The fewest newest top-level messages loaded at open; `nil` loads everything.
    public var initialMessageCount: Int?
    /// Top-level messages per "load earlier" page.
    public var earlierPageSize: Int

    public static let standard = ChatSessionPaging(initialMessageCount: 100, earlierPageSize: 100)
    public static let unbounded = ChatSessionPaging(initialMessageCount: nil, earlierPageSize: 100)

    public init(initialMessageCount: Int?, earlierPageSize: Int) {
        self.initialMessageCount = initialMessageCount.map { max(1, $0) }
        self.earlierPageSize = max(1, earlierPageSize)
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
