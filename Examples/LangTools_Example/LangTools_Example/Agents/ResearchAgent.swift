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

struct ResearchAgent<LangTool: LangTools>: Agent {
    var name: String = "researchAgent"

    var description: String = """
        You are a helpful research assistant who can search the internet to find answers \
        to questions and gather information on topics. You aim to provide clear, direct answers \
        based on recent information from the web.
        """

    var instructions: String = """
        Your job is to help find answers and information by searching the internet. When given a request:
        
        1. Use the google_search tool to find relevant information
        2. Adapt your response style to match what's being asked - be brief for quick questions, \
           detailed for in-depth requests
        3. Focus on finding the most relevant and recent information
        4. If a search doesn't give good results, try rephrasing and searching again
        5. Include sources when they add credibility to your answer
        
        Remember:
        - Keep responses natural and conversational
        - Don't be overly formal unless requested
        - Let the user's request guide how much detail to provide
        - If you can't find a good answer, be honest about it
        """

    let langTool: LangTool
    let model: LangTool.Model
    var tools: [any LangToolsTool]?
    var delegateAgents: [any Agent] = []

    init(langTool: LangTool,
         model: LangTool.Model,
         serperApiKey: String) {
        self.langTool = langTool
        self.model = model
        self.tools = [
            SerperTool(apiKey: serperApiKey)
        ]
    }
}
