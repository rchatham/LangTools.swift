//
//  WebFetchTool.swift
//  CLI
//
//  Tool for fetching content from URLs
//

import Foundation
import OpenAI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
            try NetworkDestinationValidator.validate(url: url)
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Mozilla/5.0 (compatible; LangTools-CLI/1.0)", forHTTPHeaderField: "User-Agent")

            let redirectDelegate = SafeRedirectDelegate()
            let session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)

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

final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              (try? NetworkDestinationValidator.validate(url: url)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum NetworkDestinationValidator {
    static func validate(url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw ToolError.invalidParameters(tool: WebFetchTool.name, reason: "Only HTTPS URLs are allowed")
        }
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard normalizedHost != "localhost", !normalizedHost.hasSuffix(".localhost") else { throw blocked(host) }

        if isIPAddress(normalizedHost) {
            guard isPublicIPAddress(normalizedHost) else { throw blocked(host) }
            return
        }

        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(normalizedHost, nil, nil, &addresses) == 0, let first = addresses else {
            throw ToolError.executionFailed(tool: WebFetchTool.name, reason: "Could not resolve host: \(host)")
        }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        var resolvedAny = false
        while let address = current {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address.pointee.ai_addr, address.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                resolvedAny = true
                guard isPublicIPAddress(String(cString: buffer)) else { throw blocked(host) }
            }
            current = address.pointee.ai_next
        }
        guard resolvedAny else {
            throw ToolError.executionFailed(tool: WebFetchTool.name, reason: "Could not resolve host: \(host)")
        }
    }

    static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }

    static func isPublicIPAddress(_ value: String) -> Bool {
        if let octets = ipv4Octets(value) {
            let a = octets[0], b = octets[1]
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 100 && (64...127).contains(b) { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && (b == 0 || b == 168) { return false }
            if a == 198 && (b == 18 || b == 19 || b == 51) { return false }
            if a == 203 && b == 0 { return false }
            return true
        }

        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        return (bytes[0] & 0xE0) == 0x20
    }

    private static func ipv4Octets(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    private static func blocked(_ host: String) -> ToolError {
        .invalidParameters(tool: WebFetchTool.name, reason: "Blocked non-public destination: \(host)")
    }
}
