//
//  ContentCardsContent.swift
//  Chat
//
//  Created by Claude on 2/9/26.
//

import Foundation

/// Content card data for structured agent responses
public struct ContentCardsContent: Codable, Equatable, Hashable {
    public let cardType: String
    public let message: String?
    public let cardsJSON: String
    public let cardCount: Int

    public init(cardType: String, message: String?, cardsJSON: String, cardCount: Int) {
        self.cardType = cardType
        self.message = message
        self.cardsJSON = cardsJSON
        self.cardCount = cardCount
    }

    public func decodeCards<T: Decodable>(as type: T.Type) throws -> [T] {
        guard let data = cardsJSON.data(using: .utf8) else {
            throw ContentCardsError.invalidJSON
        }
        return try JSONDecoder().decode([T].self, from: data)
    }
}

public extension ContentCardsContent {
    /// Provider-facing context for this card payload.
    ///
    /// `Message.text` intentionally exposes only the terse `message` summary
    /// for display in the chat UI. When history is replayed to an AI provider,
    /// though, the model needs the structured card details it originally
    /// produced or all card context is lost on follow-up turns. This
    /// representation contains:
    ///
    /// - the terse summary (`message`),
    /// - card metadata (`cardType` and `cardCount`), and
    /// - the card details as stable, pretty-printed JSON with sorted keys,
    ///   parsed from `cardsJSON` with `JSONSerialization`.
    ///
    /// If `cardsJSON` is not valid JSON, a clearly labeled fallback embeds the
    /// raw payload verbatim instead of throwing, so replay never fails.
    var providerContext: String {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let cached = Self.providerContextCache[self] { return cached }

        var lines: [String] = []
        if let message, !message.isEmpty {
            lines.append(message)
            lines.append("")
        }
        lines.append("Content cards (cardType: \(cardType), count: \(cardCount)):")
        if let prettyJSON = Self.prettyPrintedSortedJSON(from: cardsJSON) {
            lines.append(prettyJSON)
        } else {
            lines.append("Card details unavailable: the stored cards payload is not valid JSON. Raw payload:")
            lines.append(cardsJSON)
        }
        let rendered = lines.joined(separator: "\n")
        Self.providerContextCache[self] = rendered
        return rendered
    }

    /// Parses `cardsJSON` with `JSONSerialization` and re-renders it as stable,
    /// pretty-printed JSON with sorted keys. Returns `nil` when the payload is
    /// not valid JSON.
    static func prettyPrintedSortedJSON(from cardsJSON: String) -> String? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if Self.prettyJSONCache.index(forKey: cardsJSON) != nil {
            return Self.prettyJSONCache[cardsJSON] ?? nil
        }

        let rendered: String?
        if let data = cardsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           let string = String(data: pretty, encoding: .utf8) {
            rendered = string
        } else {
            rendered = nil
        }
        Self.prettyJSONCache[cardsJSON] = rendered
        return rendered
    }

    // MARK: - Rendering caches

    /// Reentrant lock guarding the memoization tables below. `providerContext`
    /// calls `prettyPrintedSortedJSON` internally, so a single recursive lock
    /// keeps the nested lookup from deadlocking while still protecting both
    /// caches from concurrent access.
    private static let cacheLock = NSRecursiveLock()
    /// Memoized full provider-context strings keyed by the immutable content.
    private static var providerContextCache: [ContentCardsContent: String] = [:]
    /// Memoized pretty-printed JSON keyed by the raw payload. Values are
    /// `String?` so a previously-rendered `nil` (malformed JSON) is also cached.
    private static var prettyJSONCache: [String: String?] = [:]
}

public enum ContentCardsError: Error {
    case invalidJSON
    case decodingFailed
}

/// Marker for content cards embedded in string content
public struct ContentCardsMarker: Codable, Equatable {
    public let prefix: String
    public let type: String

    public init(prefix: String, type: String) {
        self.prefix = prefix
        self.type = type
    }
}
