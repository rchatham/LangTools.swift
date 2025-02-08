//
//  Agent.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 2/5/25.
//

import Foundation
import LangTools
import Anthropic
import OpenAI
import Agents

struct ResearchAgent: Agent {
    typealias LangTool = Anthropic
    var name: String = "researchAgent"

    var description: String = """
        You are a research agent with the intention of taking in a topic and some other information from a user\
        and to then formulate a research report based on you prior knowledge but more specifically the \
        information provided.
    """

    var instructions: String = """
    """

    var langTool = Anthropic(configuration: .init(apiKey: ""))
    var model = Anthropic.Model.claude35Sonnet_latest
    var tools: [Tool]? = []
    var delegateAgents: [any Agent] = []
}
