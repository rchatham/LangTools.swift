//
//  SerperTool.swift
//  LangToolsApp
//
//  Created by Reid Chatham on 2/13/25.
//

import Foundation
import LangTools
import Agents

// MARK: - Serper Tool
public struct SerperTool: LangToolsTool {
    public let name: String
    public let description: String?
    public let tool_schema: ToolSchema<ToolSchemaProperty>
    @CodableIgnored
    public var callback: ((LangToolsRequestInfo, [String:JSON]) async throws -> String?)?

    public init(apiKey: String, session: URLSession = .shared) {
        self.init(apiKeyProvider: { apiKey }, session: session)
    }

    /// The resolver is native-only and runs at execution, never during encoding/startup.
    public init(apiKeyProvider: @escaping () throws -> String?, session: URLSession = .shared) {
        self.name = "google_search"
        self.description = "Search Google for information about a topic"
        self.tool_schema = .init(
            properties: [
                "query": .init(
                    type: "string",
                    description: "The search query"
                ),
                "num_results": .init(
                    type: "integer",
                    description: "Number of results to return (optional, default 10)"
                )
            ],
            required: ["query"]
        )

        self.callback = { _, args in
            try Task.checkCancellation()
            guard let query = args["query"]?.stringValue else {
                throw AgentError("Missing required query parameter")
            }

            let apiKey: String?
            do {
                apiKey = try apiKeyProvider()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AgentError("Research credentials are unavailable. Check native settings.")
            }
            guard let apiKey, !apiKey.isEmpty else {
                throw AgentError("Configure a Serper API key in native settings to use google_search.")
            }
            try Task.checkCancellation()
            let service = SerperService(apiKey: apiKey, session: session)
            let numResults = args["num_results"]?.intValue ?? 10

            do {
                let parameters = SerperService.SearchParameters(query: query, numResults: numResults)
                let results = try await service.search(parameters: parameters)

                // Format results into a readable string
                var output = "Search Results for '\(query)':\n\n"

                if let kg = results.knowledgeGraph {
                    output += "Knowledge Graph:\n"
                    output += "Title: \(kg.title ?? "N/A")\n"
                    output += "Type: \(kg.type ?? "N/A")\n"
                    output += "Description: \(kg.description ?? "N/A")\n\n"
                }

                output += "Organic Results:\n"
                for result in results.organic {
                    output += "\n\(result.position). \(result.title)\n"
                    output += "Link: \(result.link)\n"
                    if let snippet = result.snippet {
                        output += "Summary: \(snippet)\n"
                    }
                }

                return output
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Arbitrary transport errors can contain request headers/credentials.
                throw AgentError("Research search failed. Check native settings and try again.")
            }
        }
    }

    public init(name: String, description: String?, tool_schema: ToolSchema<ToolSchemaProperty>, callback: ((LangToolsRequestInfo, [String:JSON]) async throws -> String?)?) {
        fatalError("Not implemented for the current tool. Must instantiate using a different initializer.")
    }
}
