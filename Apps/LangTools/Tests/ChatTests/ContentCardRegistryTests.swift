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
    func testAgentAndToolEntriesHaveIdenticalDecodeContracts() throws {
        let registry = ContentCardRegistry.shared
        let key = UUID().uuidString
        let cardType = UUID().uuidString
        let decode: (String) -> (message: String?, items: [SampleCard])? = { input in
            guard input != "invalid" else { return nil }
            return ("Summary", input == "empty" ? [] : [SampleCard(title: input)])
        }
        registry.register(agent: key, cardType: cardType, as: SampleCard.self,
                          decode: decode, render: { _ in Text("Cards") })
        registry.register(tool: key, cardType: cardType, as: SampleCard.self,
                          decode: decode, render: { _ in Text("Cards") })
        for input in ["invalid", "empty", "one"] {
            let agent = registry.parseResult(input, for: key)
            let tool = registry.parseToolResult(input, for: key)
            XCTAssertEqual(agent?.cardType, tool?.cardType)
            XCTAssertEqual(agent?.message, tool?.message)
            XCTAssertEqual(agent?.cardsJSON, tool?.cardsJSON)
            XCTAssertEqual(agent?.cardCount, tool?.cardCount)
            if input == "invalid" {
                XCTAssertNil(agent)
                XCTAssertNil(tool)
            } else {
                XCTAssertEqual(try XCTUnwrap(agent).cardCount, input == "empty" ? 0 : 1)
            }
        }
    }

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
