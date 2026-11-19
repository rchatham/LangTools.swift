//
//  Agent.swift
//  LangToolsApp
//
//  Created by Reid Chatham on 2/5/25.
//

import Foundation
import LangTools
import Agents

public struct ResearchAgent: Agent {
    public var name: String = "researchAgent"

    public var description: String = """
        Perform in-depth research on topics using internet sources and AI analysis. \
        Can handle natural language requests like "Research quantum computing advances" or \
        "What are the latest developments in AI safety?"
        """

    public var instructions: String {
        let baseInstructions = """
            You are a helpful research assistant who can search the internet to find answers \
            to questions and gather information on topics. You can both search the web and analyze \
            specific webpages in depth. You aim to provide clear, direct answers based on recent \
            information from the web. Your job is to help find answers and information by searching \
            the internet. When given a request:
            
            1. Use the google_search tool to find relevant information
            2. Adapt your response style to match what's being asked - be brief for quick questions, \
               detailed for in-depth requests
            3. Focus on finding the most relevant and recent information
            4. If a search doesn't give good results, try rephrasing and searching again
            5. Include sources when they add credibility to your answer
            6. Always summarize webpages found in search results by delegating to webScrapingAgent
            
            Remember:
            - Keep responses natural and conversational
            - Don't be overly formal unless requested
            - Let the user's request guide how much detail to provide
            - If you can't find a good answer, be honest about it
            - Use the webScrapingAgent when you need to analyze specific webpages in depth
            """

        // Instructions are metadata: never access credential storage here.
        return baseInstructions + """

        If google_search reports unavailable credentials, guide the user to native settings. \
        Never request or include API keys in chat or tool arguments.
        """
    }

    public var tools: [any LangToolsTool]?
    public var delegateAgents: [any Agent] = [
        WebScrapingAgent()
    ]

    private let credentialStore: any ResearchCredentialStore
    private let session: URLSession

    /// Construction is credential-I/O-free, including the explicit-key path.
    /// The search tool resolves saved credentials only when it is invoked.
    public init(
        serperApiKey: String? = nil,
        credentialStore: any ResearchCredentialStore = StoredResearchCredentials(),
        session: URLSession = .shared
    ) {
        self.credentialStore = credentialStore
        self.session = session
        self.tools = [SerperTool(apiKeyProvider: {
            if let serperApiKey, !serperApiKey.isEmpty { return serperApiKey }
            return try credentialStore.readApiKey()
        }, session: session)]
    }

    /// Only an explicit native configuration action persists credentials.
    /// A failed save leaves the current tool and preferences unchanged.
    public mutating func updateApiKey(_ apiKey: String) throws {
        guard !apiKey.isEmpty else { throw ResearchCredentialError.emptyKey }
        do {
            try credentialStore.saveApiKey(apiKey)
        } catch {
            throw ResearchCredentialError.storageUnavailable
        }
        tools = [SerperTool(apiKey: apiKey, session: session)]
    }
}
