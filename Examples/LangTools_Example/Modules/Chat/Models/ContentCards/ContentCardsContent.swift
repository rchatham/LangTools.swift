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
        return lines.joined(separator: "\n")
    }

    /// Parses `cardsJSON` with `JSONSerialization` and re-renders it as stable,
    /// pretty-printed JSON with sorted keys. Returns `nil` when the payload is
    /// not valid JSON.
    static func prettyPrintedSortedJSON(from cardsJSON: String) -> String? {
        if let cached = Self.prettyJSONCache.value(forKey: cardsJSON) { return cached }

        guard let data = cardsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let rendered = String(data: pretty, encoding: .utf8) else {
            return nil
        }
        Self.prettyJSONCache.insert(rendered, forKey: cardsJSON)
        return rendered
    }

    // Keep expensive JSON formatting bounded by the combined UTF-8 size of
    // each raw payload and rendered value. Full provider contexts and malformed
    // raw payloads are never retained by a process-global cache.
    private static let prettyJSONCache = ContentCardsJSONCache(costLimit: 1_048_576)
}

/// A strict, lock-protected least-recently-used cache for rendered card JSON.
/// Its internal visibility supports deterministic capacity and concurrency tests.
final class ContentCardsJSONCache: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let entryCount: Int
        let totalCost: Int
        let costLimit: Int
    }

    private struct Entry {
        let value: String
        let cost: Int
        var accessOrder: UInt64
    }

    private let lock = NSLock()
    private let costLimit: Int
    private var entries: [String: Entry] = [:]
    private var totalCost = 0
    private var accessOrder: UInt64 = 0

    init(costLimit: Int) {
        self.costLimit = max(0, costLimit)
    }

    func value(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        entry.accessOrder = nextAccessOrder()
        entries[key] = entry
        return entry.value
    }

    func insert(_ value: String, forKey key: String) {
        let cost = key.utf8.count + value.utf8.count
        guard costLimit > 0, cost <= costLimit else { return }

        lock.lock()
        defer { lock.unlock() }
        if let replaced = entries.removeValue(forKey: key) {
            totalCost -= replaced.cost
        }
        while totalCost + cost > costLimit,
              let leastRecentlyUsedKey = entries.min(by: {
                  $0.value.accessOrder < $1.value.accessOrder
              })?.key,
              let evicted = entries.removeValue(forKey: leastRecentlyUsedKey) {
            totalCost -= evicted.cost
        }
        entries[key] = Entry(value: value, cost: cost, accessOrder: nextAccessOrder())
        totalCost += cost
    }

    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[key] != nil
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(entryCount: entries.count, totalCost: totalCost, costLimit: costLimit)
    }

    private func nextAccessOrder() -> UInt64 {
        accessOrder &+= 1
        return accessOrder
    }
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
