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
