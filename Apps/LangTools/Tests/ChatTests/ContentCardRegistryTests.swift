import Chat
import Foundation
import LangTools
import SwiftUI
import XCTest

private struct SampleCard: StructuredOutput {
    let title: String

    static var jsonSchema: JSONSchema {
        .object(properties: ["title": .string(description: "Title")], required: ["title"])
    }
}

final class ContentCardRegistryTests: XCTestCase {
    func testEmptyCardsDoNotCreateSecondAssistantSummary() {
        let registry = ContentCardRegistry.shared
        let agentName = UUID().uuidString
        registry.register(agent: agentName, cardType: UUID().uuidString, as: SampleCard.self,
                          decode: { _ in (message: "No events found", items: []) },
                          render: { _ in Text("Cards") })

        XCTAssertEqual(registry.parseResult("{}", for: agentName)?.cardCount, 0)
        XCTAssertNil(registry.agentResultParser("{}", agentName))
    }

    func testNonemptyCardsStillCreateContentCardsMessage() {
        let registry = ContentCardRegistry.shared
        let agentName = UUID().uuidString
        registry.register(agent: agentName, cardType: UUID().uuidString, as: SampleCard.self,
                          decode: { _ in (message: "Found one", items: [SampleCard(title: "Event")]) },
                          render: { _ in Text("Cards") })

        let message = registry.agentResultParser("{}", agentName)
        guard case .contentCards(let content) = message?.contentType else {
            return XCTFail("Expected a structured assistant message when cards exist")
        }
        XCTAssertEqual(content.cardCount, 1)
        XCTAssertEqual(content.message, "Found one")
    }
}
