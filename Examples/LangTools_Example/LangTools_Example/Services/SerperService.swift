//
//  SerperService.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 2/13/25.
//


import Foundation
import LangTools
import Agents

// MARK: - Serper Service
public class SerperService {
    private let apiKey: String
    private let baseURL = "https://google.serper.dev"
    
    public init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    public enum Endpoint: String {
        case search = "/search"
        case news = "/news"
    }
    
    public struct SearchParameters: Codable {
        let q: String
        let num: Int?
        
        public init(query: String, numResults: Int? = 10) {
            self.q = query
            self.num = numResults
        }
    }
    
    public struct SearchResult: Codable {
        public let searchParameters: SearchParameters
        public let organic: [OrganicResult]
        public let knowledgeGraph: KnowledgeGraph?
        
        public struct OrganicResult: Codable {
            public let title: String
            public let link: String
            public let snippet: String?
            public let position: Int
        }
        
        public struct KnowledgeGraph: Codable {
            public let title: String?
            public let type: String?
            public let description: String?
        }
    }
    
    public func search(parameters: SearchParameters) async throws -> SearchResult {
        guard let url = URL(string: baseURL + Endpoint.search.rawValue) else {
            throw SerperError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(parameters)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SerperError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw SerperError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(SearchResult.self, from: data)
    }
}


// MARK: - Error Handling
public enum SerperError: Error {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
//    case searchErrored(_ message: String)
}
