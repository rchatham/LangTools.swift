//
//  AgentParser.swift
//  LangTools_Example
//
//  Provides the agentResultParser closure assigned to MessageService.
//
//  Each agent that uses responseSchema produces a JSON result string on
//  completion. This function looks up the registered handler in
//  ContentCardRegistry and, if found, converts the JSON into a
//  Message.contentCards so the view layer can render the appropriate card.
//  Returns nil for agents without a registered card type, letting
//  MessageService fall back to its default agent-completion event.
//
//  To add a new structured-output agent:
//    1. Call registry.register(...) in LangTools_ExampleApp.registerCardTypes().
//  No changes to this file are required.
//

import Foundation
import Chat

func parseAgentResult(_ result: String, _ agentName: String) -> Message? {
    guard let content = ContentCardRegistry.shared.parseResult(result, for: agentName)
    else { return nil }
    return Message.contentCards(content)
}
