//
//  CardRegistration.swift
//  Chat
//
//  Self-contained descriptor for registering a content card type with
//  `ContentCardRegistry`. Created declaratively by agents and passed as
//  an array to `ContentCardRegistry.register(_:)` at app startup.
//

import SwiftUI
import LangTools

/// Describes how to decode and render a content card for a specific agent.
///
/// Use the `.simple(...)` or `.custom(...)` factory methods to create instances.
/// Pass an array of these to `ContentCardRegistry.register(_:)`.
public struct CardRegistration {
    public let agentName: String
    public let cardType: String
    let _register: (ContentCardRegistry) -> Void

    /// Creates a registration for agents whose result JSON decodes directly
    /// as a single `StructuredOutput` object (wrapped in a one-element array).
    public static func simple<Item: StructuredOutput, V: View>(
        agentName: String,
        cardType: String,
        as type: Item.Type,
        @ViewBuilder render: @escaping ([Item]) -> V
    ) -> CardRegistration {
        CardRegistration(agentName: agentName, cardType: cardType) { registry in
            registry.register(agent: agentName, cardType: cardType, as: type, render: render)
        }
    }

    /// Creates a registration for agents with a wrapper response that needs
    /// custom decoding (e.g. `{ "events": [...], "message": "..." }`).
    public static func custom<Item: StructuredOutput, V: View>(
        agentName: String,
        cardType: String,
        as type: Item.Type,
        decode: @escaping (String) -> (message: String?, items: [Item])?,
        @ViewBuilder render: @escaping ([Item]) -> V
    ) -> CardRegistration {
        CardRegistration(agentName: agentName, cardType: cardType) { registry in
            registry.register(agent: agentName, cardType: cardType, as: type, decode: decode, render: render)
        }
    }
}
