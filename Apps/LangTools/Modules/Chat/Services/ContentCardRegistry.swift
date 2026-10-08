//
//  ContentCardRegistry.swift
//  Chat
//
//  Type-safe registry that binds an agent key to a StructuredOutput data type
//  and the SwiftUI view used to render it.
//
//  ## Registration (once, at app startup)
//
//      // Single top-level object:
//      registry.register(agent: "weatherAgent", cardType: "weather", as: WeatherCardData.self) { cards in
//          ForEach(cards) { WeatherCard(from: $0).cardView() }
//      }
//
//      // Wrapper response (e.g. { "events": [...], "message": "..." }):
//      registry.register(
//          agent: "calendarAgent",
//          cardType: "calendarEvent",
//          as: CalendarEventData.self,
//          decode: { json in
//              guard let r = try? CalendarAgentResponse(jsonString: json) else { return nil }
//              return (message: r.message, items: r.events)
//          },
//          render: { events in ForEach(events) { $0.cardView() } }
//      )
//
//  ## Parse path  (agentResultParser)
//
//      registry.parseResult(json, for: agentKey)   // → ContentCardsContent?
//
//  ## View path  (message content view)
//
//      registry.view(for: content)                 // → some View
//
//  ## Agent key type
//
//  The registry accepts any `Hashable` key — pass a typed enum (e.g. AgentID)
//  in app targets that have one, or plain strings in simpler contexts.
//
//  ## Thread safety
//
//  All `register()` calls must happen synchronously at app startup on the main
//  thread, before any concurrent parsing or rendering begins. After that the
//  registry is effectively immutable and safe to read concurrently.
//

import Foundation
import os
import SwiftUI
import ChatUI
import LangTools

// MARK: - ContentCardRegistry

/// Type-safe registry that maps agent identifiers to their structured output types
/// and the SwiftUI views used to render them as content cards.
///
/// - Important: `ContentCardRegistry` is **not** `@MainActor`-isolated, but its
///   `view(for:)` method returns SwiftUI views and must be called on the main thread.
///   `register(...)` and `agentResultParser` may be called from any context, but
///   registration is typically done once at app startup on the main thread.
///   Access `shared` only after the app has finished launching.
public final class ContentCardRegistry: @unchecked Sendable {

    public static let shared = ContentCardRegistry()
    private init() {}

    // MARK: - Internal storage

    private struct Entry {
        /// Converts raw agent result JSON → ContentCardsContent (for messaging / persistence).
        let parseResult: (String) -> ContentCardsContent?
        /// Converts a ContentCardsContent → type-erased SwiftUI view (for rendering).
        let buildView: @MainActor @Sendable (ContentCardsContent, Bool) -> AnyView
    }

    private struct Storage {
        var byAgentKey: [AnyHashable: Entry] = [:]
        var byToolName: [AnyHashable: Entry] = [:]
        var byCardType: [String: Entry] = [:]
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    // MARK: - Registration

    /// Register a card type with full control over decoding and rendering.
    ///
    /// - Parameters:
    ///   - agent:    Any `Hashable` agent key (e.g. an `AgentID` enum case or a plain `String`).
    ///   - cardType: Stable string key written into `ContentCardsContent.cardType`.
    ///               It survives persistence, so never change it for an existing agent.
    ///   - type:     The `StructuredOutput` type the registry encodes/decodes.
    ///   - decode:   Converts the raw agent result JSON into `(message?, [Item])`.
    ///               The optional message appears above the cards in the UI.
    ///               Return `nil` if the JSON cannot be decoded.
    ///   - render:   `@ViewBuilder` that turns the decoded items into a SwiftUI view.
    public func register<AgentKey: Hashable, Item: StructuredOutput, V: View>(
        agent: AgentKey,
        cardType: String,
        as type: Item.Type,
        decode: @escaping (String) -> (message: String?, items: [Item])?,
        @ViewBuilder render: @escaping @Sendable ([Item]) -> V
    ) {
        let entry = Entry(
            parseResult: { json in
                guard let (message, items) = decode(json),
                      let data = try? JSONEncoder().encode(items),
                      let cardsJSON = String(data: data, encoding: .utf8)
                else { return nil }

                return ContentCardsContent(
                    cardType: cardType,
                    message: message,
                    cardsJSON: cardsJSON,
                    cardCount: items.count
                )
            },
            buildView: { content, showsSummary in
                guard let items = try? content.decodeCards(as: Item.self) else {
                    Self.logDecodeFailure(type: Item.self, cardType: cardType)
                    return AnyView(
                        Text("Could not display \(content.message ?? cardType + " card")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    )
                }
                return AnyView(
                    VStack(alignment: .leading, spacing: 12) {
                        if showsSummary, let summary = Self.nonemptySummary(content.message) {
                            Text(summary)
                        }
                        render(items)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                )
            }
        )

        storage.withLock {
            $0.byAgentKey[AnyHashable(agent)] = entry
            $0.byCardType[cardType] = entry
        }
    }

    private static func nonemptySummary(_ summary: String?) -> String? {
        guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return summary
    }

    /// Non-fatal log for stale/corrupt persisted display payloads.
    private static func logDecodeFailure(type: Any.Type, cardType: String, file: StaticString = #fileID, line: UInt = #line) {
        let message = "[ContentCardRegistry] Failed to decode \(type) from cardsJSON for cardType '\(cardType)'. Data may be stale or from a different app version."
        #if DEBUG
        print(message)
        #endif
    }

    /// Convenience overload for agents whose result is a single top-level `StructuredOutput`
    /// object (not a wrapper response). The JSON is decoded directly as `Item` and wrapped
    /// in a one-element array before being passed to `render`.
    public func register<AgentKey: Hashable, Item: StructuredOutput, V: View>(
        agent: AgentKey,
        cardType: String,
        as type: Item.Type,
        @ViewBuilder render: @escaping @Sendable ([Item]) -> V
    ) {
        register(
            agent: agent,
            cardType: cardType,
            as: type,
            decode: { json in
                guard let item = try? Item(jsonString: json) else { return nil }
                return (message: nil, items: [item])
            },
            render: render
        )
    }

    // MARK: - Parse path

    /// Convert a raw agent result JSON string into a `ContentCardsContent` ready for
    /// embedding in a `Message`. Returns `nil` if no registration exists for the agent
    /// key or if the decode closure returns `nil`.
    public func parseResult<AgentKey: Hashable>(_ json: String, for agentKey: AgentKey) -> ContentCardsContent? {
        let entry = storage.withLock { $0.byAgentKey[AnyHashable(agentKey)] }
        return entry?.parseResult(json)
    }

    /// Ready-made closure for `MessageService.agentResultParser`.
    public var agentResultParser: (String, String) -> Message? {
        { [weak self] result, agentName in
            guard let self,
                  let content = self.parseResult(result, for: agentName),
                  content.cardCount > 0
            else { return nil }
            return Message.contentCards(content)
        }
    }

    // MARK: - Tool registration

    /// Register a tool with full control over decoding and rendering.
    /// Uses a separate tool-name namespace so the same name can be registered
    /// as both an agent and a tool without collision.
    public func register<ToolKey: Hashable, Item: StructuredOutput, V: View>(
        tool: ToolKey,
        cardType: String,
        as type: Item.Type,
        decode: @escaping (String) -> (message: String?, items: [Item])?,
        @ViewBuilder render: @escaping @Sendable ([Item]) -> V
    ) {
        let entry = Entry(
            parseResult: { json in
                guard let (message, items) = decode(json),
                      let data = try? JSONEncoder().encode(items),
                      let cardsJSON = String(data: data, encoding: .utf8)
                else { return nil }
                return ContentCardsContent(cardType: cardType, message: message, cardsJSON: cardsJSON, cardCount: items.count)
            },
            buildView: { content, showsSummary in
                guard let items = try? content.decodeCards(as: Item.self) else {
                    Self.logDecodeFailure(type: Item.self, cardType: cardType)
                    return AnyView(Text("Could not display \(content.message ?? cardType + " card")").font(.subheadline).foregroundStyle(.secondary))
                }
                return AnyView(
                    VStack(alignment: .leading, spacing: 12) {
                        if showsSummary, let summary = Self.nonemptySummary(content.message) {
                            Text(summary)
                        }
                        render(items)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                )
            }
        )
        storage.withLock { $0.byToolName[AnyHashable(tool)] = entry; $0.byCardType[cardType] = entry }
    }

    /// Convenience overload for tools whose result is a single top-level `StructuredOutput`.
    public func register<ToolKey: Hashable, Item: StructuredOutput, V: View>(
        tool: ToolKey, cardType: String, as type: Item.Type,
        @ViewBuilder render: @escaping @Sendable ([Item]) -> V
    ) {
        register(tool: tool, cardType: cardType, as: type,
                  decode: { json in guard let item = try? Item(jsonString: json) else { return nil }; return (message: nil, items: [item]) },
                  render: render)
    }

    // MARK: - Tool parse path

    /// Convert a raw tool result JSON string into a `ContentCardsContent`.
    public func parseToolResult<ToolKey: Hashable>(_ json: String, for toolKey: ToolKey) -> ContentCardsContent? {
        let entry = storage.withLock { $0.byToolName[AnyHashable(toolKey)] }
        return entry?.parseResult(json)
    }

    /// Ready-made closure for `MessageService.resultContentParser`.
    public var resultContentParser: (String, String, ChatToolCall.Kind) -> ChatToolCall.DisplayContent? {
        { [weak self] result, name, kind in
            guard let self else { return nil }
            let content: ContentCardsContent? = switch kind {
            case .agent: self.parseResult(result, for: name)
            case .tool: self.parseToolResult(result, for: name)
            }
            guard let content, content.cardCount > 0 else { return nil }
            return ChatToolCall.DisplayContent(type: content.cardType, json: content.cardsJSON, summary: content.message, itemCount: content.cardCount)
        }
    }

    // MARK: - DisplayContent view path

    /// Build an attached result view, including its nonempty summary above the
    /// decoded items. Decode failures and unknown types retain a single fallback.
    @MainActor @ViewBuilder
    public func view(for displayContent: ChatToolCall.DisplayContent) -> some View {
        let entry: Entry? = storage.withLock { $0.byCardType[displayContent.type] }
        if let entry {
            let content = ContentCardsContent(cardType: displayContent.type, message: displayContent.summary, cardsJSON: displayContent.json, cardCount: displayContent.itemCount)
            entry.buildView(content, true)
        } else {
            Text(Self.nonemptySummary(displayContent.summary) ?? "Unknown card type: \(displayContent.type)").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: - View path

    /// Build legacy standalone cards. Their summary is already presented by
    /// `Message.text`, so do not repeat it in the registered item renderer.
    @MainActor @ViewBuilder
    public func view(for content: ContentCardsContent) -> some View {
        let entry: Entry? = storage.withLock { $0.byCardType[content.cardType] }
        if let entry { entry.buildView(content, false) }
        else { Text(content.message ?? "Unknown card type: \(content.cardType)").font(.subheadline).foregroundStyle(.secondary) }
    }

    // MARK: - Batch registration

    /// Register an array of card registrations (typically from `AgentRegistry.cardRegistrations`).
    public func register(_ registrations: [CardRegistration]) {
        for registration in registrations {
            registration._register(self)
        }
    }
}
