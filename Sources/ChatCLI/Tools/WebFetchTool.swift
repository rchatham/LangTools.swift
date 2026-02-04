//
//  WebFetchTool.swift
//  ChatCLI
//
//  Tool for fetching content from URLs
//

import Foundation
import OpenAI

/// Tool for fetching web content
struct WebFetchTool: ExecutableTool {
    static let name = "web_fetch"

    static let description = """
        Fetch content from a URL and process it.

        Features:
        - Fetches URL content
        - Converts HTML to plain text when possible
        - Returns content for analysis

        Usage notes:
        - URL must be fully-formed and valid
        - HTTP URLs are upgraded to HTTPS
        - Results may be summarized if content is large
        - Includes caching for repeated access
        """

    static let parametersSchema = OpenAI.Tool.FunctionSchema.Parameters(
        properties: [
            "url": .init(
                type: "string",
                description: "The URL to fetch content from"
            ),
            "prompt": .init(
                type: "string",
                description: "What information to extract from the page"
            )
        ],
        required: ["url", "prompt"]
    )

    /// Content cache
    private static var cache: [String: CachedContent] = [:]
    private static let cacheExpiration: TimeInterval = 15 * 60 // 15 minutes

    private struct CachedContent {
        let content: String
        let fetchedAt: Date
    }

    static func execute(parameters: [String: Any]) async throws -> String {
        guard let urlString = ToolRegistry.extractString(parameters, key: "url") else {
            throw ToolError.missingRequiredParameter(tool: name, parameter: "url")
        }

        let prompt = ToolRegistry.extractString(parameters, key: "prompt") ?? "Extract the main content"

        // Normalize URL
        var normalizedUrl = urlString
        if !normalizedUrl.lowercased().hasPrefix("http://") && !normalizedUrl.lowercased().hasPrefix("https://") {
            normalizedUrl = "https://\(urlString)"
        } else if normalizedUrl.lowercased().hasPrefix("http://") {
            normalizedUrl = "https://\(normalizedUrl.dropFirst(7))"
        }

        // Check cache
        if let cached = cache[normalizedUrl], Date().timeIntervalSince(cached.fetchedAt) < cacheExpiration {
            return processContent(cached.content, prompt: prompt)
        }

        // Fetch content
        guard let url = URL(string: normalizedUrl) else {
            throw ToolError.invalidParameters(tool: name, reason: "Invalid URL: \(urlString)")
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Mozilla/5.0 (compatible; ChatCLI/1.0)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ToolError.executionFailed(tool: name, reason: "Invalid response")
            }

            // Check for redirect
            if httpResponse.statusCode >= 300 && httpResponse.statusCode < 400,
               let location = httpResponse.value(forHTTPHeaderField: "Location") {
                return """
                Redirect detected.
                Original URL: \(urlString)
                Redirect URL: \(location)

                Please make a new request with the redirect URL to fetch the content.
                """
            }

            guard httpResponse.statusCode == 200 else {
                throw ToolError.executionFailed(tool: name, reason: "HTTP \(httpResponse.statusCode)")
            }

            guard let content = String(data: data, encoding: .utf8) else {
                throw ToolError.executionFailed(tool: name, reason: "Could not decode content")
            }

            // Process HTML to plain text
            let processedContent = stripHtml(content)

            // Cache the result
            cache[normalizedUrl] = CachedContent(content: processedContent, fetchedAt: Date())

            return processContent(processedContent, prompt: prompt)
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.executionFailed(tool: name, reason: error.localizedDescription)
        }
    }

    private static func stripHtml(_ html: String) -> String {
        var text = html

        // Remove script and style blocks
        text = text.replacingOccurrences(
            of: "<script[^>]*>.*?</script>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<style[^>]*>.*?</style>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove HTML tags
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // Decode common HTML entities
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'")
        ]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }

        // Clean up whitespace
        text = text.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\n\\s*\\n+",
            with: "\n\n",
            options: .regularExpression
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func processContent(_ content: String, prompt: String) -> String {
        // Truncate if too long
        let maxLength = 30000
        let truncated = content.count > maxLength
        let processedContent = truncated ? String(content.prefix(maxLength)) : content

        var result = """
        URL Content:
        ============

        \(processedContent)
        """

        if truncated {
            result += "\n\n[Content truncated - showing first \(maxLength) characters of \(content.count) total]"
        }

        result += "\n\n---\nPrompt: \(prompt)"

        return result
    }
}
