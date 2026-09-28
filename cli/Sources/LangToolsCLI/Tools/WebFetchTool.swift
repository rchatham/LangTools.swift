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
            let (data, httpResponse) = try await fetchData(
                from: url,
                resolver: SystemNetworkAddressResolver(),
                transport: CurlPinnedHTTPSTransport()
            )

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

    static func fetchData(
        from initialURL: URL,
        resolver: NetworkAddressResolving,
        transport: PinnedHTTPSTransport,
        maximumRedirects: Int = 5
    ) async throws -> (Data, HTTPURLResponse) {
        var url = initialURL
        for redirectCount in 0...maximumRedirects {
            let destination = try NetworkDestinationValidator.resolveAndValidate(url: url, resolver: resolver)
            let (data, response) = try await transport.fetch(url: url, pinnedAddress: destination.address)

            guard (300..<400).contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let redirectedURL = URL(string: location, relativeTo: url)?.absoluteURL else {
                return (data, response)
            }
            guard redirectCount < maximumRedirects else {
                throw ToolError.executionFailed(tool: name, reason: "Too many redirects")
            }
            // The next loop validates and pins the redirect before connecting to it.
            url = redirectedURL
        }
        throw ToolError.executionFailed(tool: name, reason: "Too many redirects")
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

protocol NetworkAddressResolving {
    func addresses(for host: String) throws -> [String]
}

struct SystemNetworkAddressResolver: NetworkAddressResolving {
    func addresses(for host: String) throws -> [String] {
        if NetworkDestinationValidator.isIPAddress(host) { return [host] }
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, nil, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }

        var values: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let item = current {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: buffer)
                if !values.contains(value) { values.append(value) }
            }
            current = item.pointee.ai_next
        }
        return values
    }
}

struct ResolvedNetworkDestination {
    let address: String
}

protocol PinnedHTTPSTransport {
    func fetch(url: URL, pinnedAddress: String) async throws -> (Data, HTTPURLResponse)
}

struct CurlPinnedHTTPSTransport: PinnedHTTPSTransport {
    func fetch(url: URL, pinnedAddress: String) async throws -> (Data, HTTPURLResponse) {
        guard let host = url.host else { throw URLError(.badURL) }
        let port = url.port ?? 443
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let bodyURL = directory.appendingPathComponent("body")
        let headersURL = directory.appendingPathComponent("headers")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        let curlAddress = pinnedAddress.contains(":") ? "[\(pinnedAddress)]" : pinnedAddress
        process.arguments = [
            "--silent", "--show-error", "--noproxy", "*", "--max-time", "30",
            "--max-redirs", "0", "--resolve", "\(host):\(port):\(curlAddress)",
            "--user-agent", "Mozilla/5.0 (compatible; LangTools-CLI/1.0)",
            "--dump-header", headersURL.path, "--output", bodyURL.path,
            "--write-out", "%{http_code}", url.absoluteString
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let statusText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, let status = Int(statusText) else {
            throw ToolError.executionFailed(tool: WebFetchTool.name, reason: errorText.isEmpty ? "HTTPS request failed" : errorText)
        }
        let body = try Data(contentsOf: bodyURL)
        let headerText = (try? String(contentsOf: headersURL, encoding: .utf8)) ?? ""
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<separator])] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw ToolError.executionFailed(tool: WebFetchTool.name, reason: "Invalid response")
        }
        return (body, response)
    }
}

enum NetworkDestinationValidator {
    static func validate(url: URL) throws {
        _ = try resolveAndValidate(url: url, resolver: SystemNetworkAddressResolver())
    }

    static func resolveAndValidate(url: URL, resolver: NetworkAddressResolving) throws -> ResolvedNetworkDestination {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw ToolError.invalidParameters(tool: WebFetchTool.name, reason: "Only HTTPS URLs are allowed")
        }
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard normalizedHost != "localhost", !normalizedHost.hasSuffix(".localhost") else { throw blocked(host) }

        let addresses = try resolver.addresses(for: normalizedHost)
        guard !addresses.isEmpty else {
            throw ToolError.executionFailed(tool: WebFetchTool.name, reason: "Could not resolve host: \(host)")
        }
        guard addresses.allSatisfy(isPublicIPAddress) else { throw blocked(host) }
        return ResolvedNetworkDestination(address: addresses[0])
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
