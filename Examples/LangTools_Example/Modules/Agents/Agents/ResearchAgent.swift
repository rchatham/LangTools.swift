//
//  Agent.swift
//  LangTools_Example
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
        
        // Add API key missing notice if needed
        if isApiKeyMissing {
            return baseInstructions + """
            
            NOTE: The Serper API key is missing. You will need to ask the user to provide a Serper API key \
            for the google_search functionality to work. Explain that the research capabilities require \
            a Serper API key and guide them on how to enter it through settings.
            """
        }
        
        return baseInstructions
    }

    public var tools: [any LangToolsTool]?
    public var delegateAgents: [any Agent] = []

    // Computed property to check if API key is missing using both UserDefaults and Keychain
    var isApiKeyMissing: Bool {
        // First check UserDefaults (faster)
        if let userDefaultsKey = UserDefaults.serperApiKey, !userDefaultsKey.isEmpty {
            return false
        }
        
        // Then check Keychain as backup
        let keychainKey = KeychainService().getApiKey(for: .serper)
        return keychainKey == nil || keychainKey?.isEmpty == true
    }

    public init(serperApiKey: String? = nil) {
        // Try to get API key from UserDefaults first
        var apiKey = UserDefaults.serperApiKey
        
        // If not in UserDefaults, try Keychain
        if apiKey == nil || apiKey?.isEmpty == true {
            apiKey = KeychainService().getApiKey(for: .serper)
            
            // If we found a key in Keychain, sync it to UserDefaults
            if let apiKey = apiKey, !apiKey.isEmpty {
                UserDefaults.serperApiKey = apiKey
            }
        }
        
        // If explicit API key is provided, use that instead
        if let serperApiKey = serperApiKey, !serperApiKey.isEmpty {
            apiKey = serperApiKey
        }
        
        setupTools(with: apiKey)
    }
    
    mutating func setupTools(with apiKey: String?) {
        if let apiKey, !apiKey.isEmpty {
            // Update both UserDefaults and Keychain
            UserDefaults.serperApiKey = apiKey
            KeychainService().saveApiKey(apiKey: apiKey, for: .serper)
            
            self.tools = [
                SerperTool(apiKey: apiKey)
            ]
        } else {
            self.tools = []
        }
    }
    
    // Method to update API key
    mutating func updateApiKey(_ apiKey: String) {
        setupTools(with: apiKey)
    }
    
    // Check if the agent has a valid API key
    var hasValidApiKey: Bool {
        return !isApiKeyMissing
    }
}
