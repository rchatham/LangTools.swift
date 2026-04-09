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
import SwiftUI
import LangTools

// MARK: - ContentCardRegistry

public final class ContentCardRegistry: @unchecked Sendable {

    public static let shared = ContentCardRegistry()
    private init() {}

    // MARK: - Internal storage

    private struct Entry {
        /// Converts raw agent result JSON → ContentCardsContent (for messaging / persistence).
        let parseResult: (String) -> ContentCardsContent?
        /// Converts a ContentCardsContent → type-erased SwiftUI view (for rendering).
        let buildView: (ContentCardsContent) -> AnyView
    }

    /// Keyed by agent key (AnyHashable) — used by the parse path.
    private var byAgentKey: [AnyHashable: Entry] = [:]

    /// Keyed by cardType string — used by the view path.
    /// This key is persisted inside ContentCardsContent, so it must be stable across launches.
    private var byCardType: [String: Entry] = [:]

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
        @ViewBuilder render: @escaping ([Item]) -> V
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
            buildView: { content in
                guard let items = try? content.decodeCards(as: Item.self) else {
                    #if DEBUG
                    assertionFailure(
                        "[ContentCardRegistry] Failed to decode \(Item.self) from cardsJSON " +
                        "for cardType '\(cardType)'. Encoding/decoding mismatch?"
                    )
                    #endif
                    return AnyView(
                        Text("Could not display \(content.message ?? cardType + " card")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    )
                }
                return AnyView(render(items))
            }
        )

        byAgentKey[AnyHashable(agent)] = entry
        byCardType[cardType] = entry
    }

    /// Convenience overload for agents whose result is a single top-level `StructuredOutput`
    /// object (not a wrapper response). The JSON is decoded directly as `Item` and wrapped
    /// in a one-element array before being passed to `render`.
    public func register<AgentKey: Hashable, Item: StructuredOutput, V: View>(
        agent: AgentKey,
        cardType: String,
        as type: Item.Type,
        @ViewBuilder render: @escaping ([Item]) -> V
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
        byAgentKey[AnyHashable(agentKey)]?.parseResult(json)
    }

    // MARK: - View path

    /// Build a SwiftUI view for the given content. Falls back to plain secondary text
    /// if no registration is found for `content.cardType` (e.g. cards persisted from
    /// an older app version whose type was later removed).
    @MainActor
    @ViewBuilder
    public func view(for content: ContentCardsContent) -> some View {
        if let entry = byCardType[content.cardType] {
            entry.buildView(content)
        } else {
            Text(content.message ?? "Unknown card type: \(content.cardType)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
