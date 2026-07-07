//
//  WebScrapingAgent.swift
//  App
//
//  Created by Reid Chatham on 3/5/25.
//


import Foundation
import LangTools
import Agents
import SwiftSoup

public struct WebScrapingAgent: Agent {
    public let name: String = "webScrapingAgent"
    public let description: String = "Agent responsible for web scraping and data extraction"
    public let instructions: String = """
        You are a web scraping assistant that fetches content from websites, extracts structured data,
        and processes it as requested. You can fetch web pages, extract specific information, and
        help with research tasks. Always verify the extracted information is relevant to the user's query
        and format it in a way that's easily readable.
        """

    public var delegateAgents: [any Agent] = []
    
    public init() {
    }
    
    public var tools: [any LangToolsTool]? = [
        Tool(
            name: "fetch_webpage",
            description: "Fetch the content of a web page",
            tool_schema: .init(
                properties: [
                    "url": .init(
                        type: "string",
                        description: "The URL of the webpage to fetch"
                    )
                ],
                required: ["url"]
            ),
            callback: { args in
                guard let url = args["url"]?.stringValue else {
                    throw AgentError("Missing URL parameter")
                }
                
                // Validate URL format
                guard let validURL = URL(string: url), validURL.scheme != nil, validURL.host != nil else {
                    throw AgentError("Invalid URL format: \(url)")
                }
                
                do {
                    let content = try WebScraperService.shared.fetchWebpage(url: url)
                    return content
                } catch {
                    throw AgentError("Failed to fetch webpage: \(error.localizedDescription)")
                }
            }
        ),
        
        Tool(
            name: "extract_text",
            description: "Extract main text content from HTML",
            tool_schema: .init(
                properties: [
                    "html": .init(
                        type: "string",
                        description: "HTML content to extract text from"
                    ),
                    "selector": .init(
                        type: "string",
                        description: "CSS selector to target specific elements (optional)"
                    )
                ],
                required: ["html"]
            ),
            callback: { args in
                guard let html = args["html"]?.stringValue else {
                    throw AgentError("Missing HTML content")
                }
                
                let selector = args["selector"]?.stringValue
                
                do {
                    let text = try WebScraperService.shared.extractText(from: html, selector: selector)
                    return text
                } catch {
                    throw AgentError("Failed to extract text: \(error.localizedDescription)")
                }
            }
        ),
        
        Tool(
            name: "extract_links",
            description: "Extract links from HTML content",
            tool_schema: .init(
                properties: [
                    "html": .init(
                        type: "string",
                        description: "HTML content to extract links from"
                    ),
                    "domain": .init(
                        type: "string",
                        description: "Optional domain to filter links by (returns only links containing this domain)"
                    )
                ],
                required: ["html"]
            ),
            callback: { args in
                guard let html = args["html"]?.stringValue else {
                    throw AgentError("Missing HTML content")
                }
                
                let domain = args["domain"]?.stringValue
                
                do {
                    let links = try WebScraperService.shared.extractLinks(from: html, domain: domain)
                    return links.joined(separator: "\n")
                } catch {
                    throw AgentError("Failed to extract links: \(error.localizedDescription)")
                }
            }
        ),
        
        Tool(
            name: "extract_structured_data",
            description: "Extract structured data like tables or lists from HTML",
            tool_schema: .init(
                properties: [
                    "html": .init(
                        type: "string",
                        description: "HTML content to extract data from"
                    ),
                    "selector": .init(
                        type: "string",
                        description: "CSS selector for the table, list, or other structured element"
                    ),
                    "format": .init(
                        type: "string",
                        enumValues: ["json", "markdown", "csv"],
                        description: "Format to return the structured data in"
                    )
                ],
                required: ["html", "selector"]
            ),
            callback: { args in
                guard let html = args["html"]?.stringValue else {
                    throw AgentError("Missing HTML content")
                }
                
                guard let selector = args["selector"]?.stringValue else {
                    throw AgentError("Missing selector parameter")
                }
                
                let format = args["format"]?.stringValue ?? "markdown"
                
                do {
                    let structuredData = try WebScraperService.shared.extractStructuredData(
                        from: html, 
                        selector: selector, 
                        format: format
                    )
                    return structuredData
                } catch {
                    throw AgentError("Failed to extract structured data: \(error.localizedDescription)")
                }
            }
        ),
        
        Tool(
            name: "search_in_page",
            description: "Search for specific text or pattern in webpage content",
            tool_schema: .init(
                properties: [
                    "html": .init(
                        type: "string",
                        description: "HTML content to search in"
                    ),
                    "query": .init(
                        type: "string",
                        description: "Text or pattern to search for"
                    ),
                    "case_sensitive": .init(
                        type: "boolean",
                        description: "Whether the search should be case sensitive"
                    )
                ],
                required: ["html", "query"]
            ),
            callback: { args in
                guard let html = args["html"]?.stringValue else {
                    throw AgentError("Missing HTML content")
                }
                
                guard let query = args["query"]?.stringValue else {
                    throw AgentError("Missing query parameter")
                }
                
                let caseSensitive = args["case_sensitive"]?.boolValue ?? false
                
                do {
                    let results = try WebScraperService.shared.searchInPage(
                        html: html,
                        query: query,
                        caseSensitive: caseSensitive
                    )
                    return results
                } catch {
                    throw AgentError("Failed to search in page: \(error.localizedDescription)")
                }
            }
        ),
        
        Tool(
            name: "extract_metadata",
            description: "Extract metadata from a webpage such as title, description, and other meta tags",
            tool_schema: .init(
                properties: [
                    "html": .init(
                        type: "string",
                        description: "HTML content to extract metadata from"
                    )
                ],
                required: ["html"]
            ),
            callback: { args in
                guard let html = args["html"]?.stringValue else {
                    throw AgentError("Missing HTML content")
                }
                
                do {
                    let metadata = try WebScraperService.shared.extractMetadata(from: html)
                    return metadata
                } catch {
                    throw AgentError("Failed to extract metadata: \(error.localizedDescription)")
                }
            }
        )
    ]
}
