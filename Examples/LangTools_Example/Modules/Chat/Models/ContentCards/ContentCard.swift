//
//  ContentCard.swift
//  Chat
//
//  Created by Reid Chatham on 1/27/25.
//

import Foundation
import SwiftUI
import LangTools

// MARK: - ContentCard Protocol

/// Protocol for structured content cards that can be rendered as views.
/// Bridges StructuredOutput (AI-generated) with SwiftUI views.
public protocol ContentCard: StructuredOutput, Identifiable, Equatable {
    associatedtype CardView: View

    /// Returns a SwiftUI view for rendering this card
    @ViewBuilder func cardView() -> CardView
}

// MARK: - AnyContentCard (Type Erasure)

/// Type-erased wrapper for storing heterogeneous content cards
public struct AnyContentCard: Identifiable {
    public let id: String
    public let cardType: String
    private let _cardView: () -> AnyView
    private let _jsonSchema: () -> JSONSchema
    private let _encode: (Encoder) throws -> Void

    public init<C: ContentCard>(_ card: C) where C.ID == String {
        self.id = card.id
        self.cardType = String(describing: C.self)
        self._cardView = { AnyView(card.cardView()) }
        self._jsonSchema = { C.jsonSchema }
        self._encode = { try card.encode(to: $0) }
    }

    public init<C: ContentCard>(_ card: C) where C.ID: CustomStringConvertible {
        self.id = String(describing: card.id)
        self.cardType = String(describing: C.self)
        self._cardView = { AnyView(card.cardView()) }
        self._jsonSchema = { C.jsonSchema }
        self._encode = { try card.encode(to: $0) }
    }

    @ViewBuilder
    public func cardView() -> some View {
        _cardView()
    }

    public static var jsonSchema: JSONSchema {
        // Returns a union schema for any content card type
        .object(
            properties: [
                "type": .string(description: "The type of content card"),
                "data": .object(properties: [:])
            ],
            required: ["type", "data"]
        )
    }
}

// MARK: - ContentCardCollection

/// A collection of content cards for multi-item responses
public struct ContentCardCollection: Identifiable {
    public let id: String
    public let cards: [AnyContentCard]
    public let title: String?

    public init(id: String = UUID().uuidString, cards: [AnyContentCard], title: String? = nil) {
        self.id = id
        self.cards = cards
        self.title = title
    }
}

// MARK: - Default Identifiable Conformance

public extension ContentCard where ID == String {
    var id: String { UUID().uuidString }
}
