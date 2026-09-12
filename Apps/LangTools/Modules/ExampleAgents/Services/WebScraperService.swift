//
//  WebScraperService.swift
//  App
//
//  Created by Reid Chatham on 3/5/25.
//


import Foundation
import SwiftSoup

/// Service for handling web scraping operations
public class WebScraperService {
    public static let shared = WebScraperService()
    
    private init() {}
    
    /// Custom errors for web scraping operations
    public enum ScraperError: Error {
        case invalidURL
        case networkError(Error)
        case parsingError(Error)
        case contentExtractionError(String)
        case emptyContent
        case invalidSelector
    }
    
    /// Cache for storing recently fetched webpages to reduce network calls
    private var pageCache: [String: (content: String, timestamp: Date)] = [:]
    private let cacheDuration: TimeInterval = 300 // 5 minutes
    
    /// Headers to mimic a normal browser
    private let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5"
    ]
    
    /// Fetch HTML content from a URL
    /// - Parameter url: The URL to fetch
    /// - Returns: The HTML content as a string
    public func fetchWebpage(url: String) throws -> String {
        // Check cache first
        if let cached = pageCache[url], 
           Date().timeIntervalSince(cached.timestamp) < cacheDuration {
            return cached.content
        }
        
        guard let url = URL(string: url) else {
            throw ScraperError.invalidURL
        }
        
        var request = URLRequest(url: url)
        
        // Add headers to mimic a browser
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        // Use semaphore to make this sync since it's being called from Agent tool callbacks
        let semaphore = DispatchSemaphore(value: 0)
        var htmlContent: String?
        var requestError: Error?
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                requestError = ScraperError.networkError(error)
                return
            }
            
            guard let data = data, let content = String(data: data, encoding: .utf8) else {
                requestError = ScraperError.emptyContent
                return
            }
            
            htmlContent = content
        }
        
        task.resume()
        semaphore.wait()
        
        if let error = requestError {
            throw error
        }
        
        guard let content = htmlContent else {
            throw ScraperError.emptyContent
        }
        
        // Add to cache
        pageCache[url.absoluteString] = (content, Date())
        
        return content
    }
    
    /// Extract text content from HTML
    /// - Parameters:
    ///   - html: The HTML content
    ///   - selector: Optional CSS selector to target specific elements
    /// - Returns: The extracted text
    public func extractText(from html: String, selector: String? = nil) throws -> String {
        do {
            let document = try SwiftSoup.parse(html)
            
            if let selector = selector {
                let elements = try document.select(selector)
                if elements.isEmpty() {
                    throw ScraperError.invalidSelector
                }
                return try elements.text()
            } else {
                // Remove script and style elements
                try document.select("script, style, iframe, noscript").remove()
                
                // Try to extract content from main content areas
                let contentAreas = try document.select("article, main, .content, .main, #content, #main")
                if !contentAreas.isEmpty() {
                    return try contentAreas.text()
                }
                
                // If no content areas found, extract from body with some cleaning
                let body = try document.body()
                return try body?.text() ?? ""
            }
        } catch {
            throw ScraperError.parsingError(error)
        }
    }
    
    /// Extract links from HTML content
    /// - Parameters:
    ///   - html: The HTML content
    ///   - domain: Optional domain to filter links by
    /// - Returns: Array of extracted links
    public func extractLinks(from html: String, domain: String? = nil) throws -> [String] {
        do {
            let document = try SwiftSoup.parse(html)
            let links = try document.select("a[href]")
            
            var extractedLinks = [String]()
            
            for link in links {
                let href = try link.attr("href")
                
                // Ignore empty, javascript, and anchor links
                if href.isEmpty || href.starts(with: "javascript:") || href.starts(with: "#") {
                    continue
                }
                
                // Filter by domain if provided
                if let domain = domain, !href.contains(domain) && !href.starts(with: "/") {
                    continue
                }
                
                extractedLinks.append(href)
            }
            
            return extractedLinks
        } catch {
            throw ScraperError.parsingError(error)
        }
    }
    
    /// Extract structured data like tables or lists from HTML
    /// - Parameters:
    ///   - html: The HTML content
    ///   - selector: CSS selector for the table, list, or other structured element
    ///   - format: Format to return the data in (json, markdown, or csv)
    /// - Returns: Structured data in the requested format
    public func extractStructuredData(from html: String, selector: String, format: String = "markdown") throws -> String {
        do {
            let document = try SwiftSoup.parse(html)
            let elements = try document.select(selector)
            
            if elements.isEmpty() {
                throw ScraperError.invalidSelector
            }
            
            if selector.contains("table") || elements.first()?.tagName() == "table" {
                return try extractTableData(from: elements, format: format)
            } else if selector.contains("ul") || selector.contains("ol") || 
                     elements.first()?.tagName() == "ul" || elements.first()?.tagName() == "ol" {
                return try extractListData(from: elements, format: format)
            } else {
                // Generic structured data extraction
                let data = try elements.map { try $0.text() }
                
                switch format.lowercased() {
                case "json":
                    let jsonData = try JSONSerialization.data(withJSONObject: data, options: .prettyPrinted)
                    return String(data: jsonData, encoding: .utf8) ?? ""
                case "csv":
                    return data.joined(separator: ",")
                case "markdown":
                    return data.map { "- \($0)" }.joined(separator: "\n")
                default:
                    return data.joined(separator: "\n")
                }
            }
        } catch {
            throw ScraperError.parsingError(error)
        }
    }
    
    /// Extract data from table elements
    private func extractTableData(from elements: Elements, format: String) throws -> String {
        var result = ""
        
        // Get the first table
        guard let table = elements.first() else {
            throw ScraperError.contentExtractionError("No table found")
        }
        
        // Extract headers
        let headers = try table.select("th").map { try $0.text() }
        let rows = try table.select("tr")
        
        var tableData = [[String]]()
        tableData.append(headers)
        
        // Extract rows
        for row in rows {
            let cells = try row.select("td").map { try $0.text() }
            if !cells.isEmpty {
                tableData.append(cells)
            }
        }
        
        // Format the data
        switch format.lowercased() {
        case "json":
            if headers.isEmpty {
                // If no headers, just return rows as arrays
                let jsonData = try JSONSerialization.data(withJSONObject: tableData, options: .prettyPrinted)
                result = String(data: jsonData, encoding: .utf8) ?? ""
            } else {
                // Format as array of objects using headers as keys
                var jsonArray = [[String: String]]()
                
                for i in 1..<tableData.count {
                    var rowDict = [String: String]()
                    for j in 0..<min(headers.count, tableData[i].count) {
                        rowDict[headers[j]] = tableData[i][j]
                    }
                    jsonArray.append(rowDict)
                }
                
                let jsonData = try JSONSerialization.data(withJSONObject: jsonArray, options: .prettyPrinted)
                result = String(data: jsonData, encoding: .utf8) ?? ""
            }
            
        case "csv":
            for row in tableData {
                result += row.joined(separator: ",") + "\n"
            }
            
        case "markdown":
            // Headers
            if !headers.isEmpty {
                result += "| " + headers.joined(separator: " | ") + " |\n"
                result += "| " + headers.map { String(repeating: "-", count: $0.count) }.joined(separator: " | ") + " |\n"
            }
            
            // Rows
            for i in (headers.isEmpty ? 0 : 1)..<tableData.count {
                result += "| " + tableData[i].joined(separator: " | ") + " |\n"
            }
            
        default:
            result = tableData.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        }
        
        return result
    }
    
    /// Extract data from list elements
    private func extractListData(from elements: Elements, format: String) throws -> String {
        // Get the first list
        guard let list = elements.first() else {
            throw ScraperError.contentExtractionError("No list found")
        }
        
        let items = try list.select("li").map { try $0.text() }
        
        // Format the data
        switch format.lowercased() {
        case "json":
            let jsonData = try JSONSerialization.data(withJSONObject: items, options: .prettyPrinted)
            return String(data: jsonData, encoding: .utf8) ?? ""
            
        case "csv":
            return items.joined(separator: ",")
            
        case "markdown":
            return items.map { "- \($0)" }.joined(separator: "\n")
            
        default:
            return items.joined(separator: "\n")
        }
    }
    
    /// Search for text in the HTML content
    /// - Parameters:
    ///   - html: The HTML content
    ///   - query: Text to search for
    ///   - caseSensitive: Whether the search should be case sensitive
    /// - Returns: Search results with context
    public func searchInPage(html: String, query: String, caseSensitive: Bool = false) throws -> String {
        do {
            let document = try SwiftSoup.parse(html)
            
            // Remove script and style elements
            try document.select("script, style, iframe").remove()
            
            let bodyText = try document.body()?.text() ?? ""
            let searchText = caseSensitive ? bodyText : bodyText.lowercased()
            let searchQuery = caseSensitive ? query : query.lowercased()
            
            // If query not found
            if !searchText.contains(searchQuery) {
                return "Query '\(query)' not found in the page."
            }
            
            // Find all occurrences with context
            var results = [String]()
            let paragraphs = try document.select("p, h1, h2, h3, h4, h5, h6, li, td, div")
            
            for paragraph in paragraphs {
                let text = try paragraph.text()
                let compareText = caseSensitive ? text : text.lowercased()
                
                if compareText.contains(searchQuery) {
                    results.append(text)
                }
            }
            
            if results.isEmpty {
                // If no specific elements found, extract context from body text
                let words = bodyText.components(separatedBy: .whitespacesAndNewlines)
                let searchWords = searchQuery.components(separatedBy: .whitespacesAndNewlines)
                
                for (index, word) in words.enumerated() {
                    let compareWord = caseSensitive ? word : word.lowercased()
                    
                    if compareWord.contains(searchWords.first ?? "") {
                        // Check if the entire query matches
                        let potentialMatch = words[index..<min(index + searchWords.count, words.count)].joined(separator: " ")
                        let comparePotential = caseSensitive ? potentialMatch : potentialMatch.lowercased()
                        
                        if comparePotential.contains(searchQuery) {
                            // Extract context (5 words before and after)
                            let start = max(0, index - 5)
                            let end = min(words.count, index + searchWords.count + 5)
                            let context = words[start..<end].joined(separator: " ")
                            
                            results.append("..." + context + "...")
                        }
                    }
                }
            }
            
            if results.isEmpty {
                return "Query '\(query)' found in the page but couldn't extract specific context."
            }
            
            // Format the results
            let formattedResults = "Found \(results.count) matches for '\(query)':\n\n" + 
                                  results.enumerated().map { "[\($0 + 1)] \($1)" }.joined(separator: "\n\n")
            
            return formattedResults
        } catch {
            throw ScraperError.parsingError(error)
        }
    }
    
    /// Extract metadata from a webpage
    /// - Parameter html: The HTML content
    /// - Returns: Formatted metadata string
    public func extractMetadata(from html: String) throws -> String {
        do {
            let document = try SwiftSoup.parse(html)
            var metadata = [String: String]()
            
            // Extract title
            metadata["title"] = try document.title()

            // Extract meta tags
            let metaTags = try document.select("meta")
            for tag in metaTags {
                if let name = try? tag.attr("name"), !name.isEmpty {
                    if let content = try? tag.attr("content") {
                        metadata[name] = content
                    }
                } else if let property = try? tag.attr("property"), !property.isEmpty {
                    if let content = try? tag.attr("content") {
                        metadata[property] = content
                    }
                }
            }
            
            // Format the results
            var result = "Webpage Metadata:\n"
            
            // Add title first if available
            if let title = metadata["title"] {
                result += "Title: \(title)\n"
            }
            
            // Add description if available (common meta tag)
            if let description = metadata["description"] {
                result += "Description: \(description)\n"
            }
            
            // Add other meta tags
            result += "\nAdditional Metadata:\n"
            for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
                if key != "title" && key != "description" {
                    result += "\(key): \(value)\n"
                }
            }
            
            return result
        } catch {
            throw ScraperError.parsingError(error)
        }
    }
}
