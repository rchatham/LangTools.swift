import Foundation

/// Claude Code is an external backend, not a LocalHelperServer route. Only an explicitly
/// configured numeric loopback origin can receive account credentials from this relay.
public enum MobileClaudeRelay {
    public static func validatedOrigin(_ url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http", ["127.0.0.1", "[::1]", "::1"].contains(components.host ?? ""),
              let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw MobileHelperError.upstreamRejected
        }
        return url
    }

    /// Validate a bounded complete JSON response/event before forwarding it. HTTP-200 error
    /// bodies and streaming error events are not allowed to echo account/device credentials.
    static func sanitizedJSON(_ data: Data, accountToken: String?, deviceToken: String?, event: Bool) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        if let fields = object as? [String: Any], fields["type"] as? String == "error" || fields["error"].map({ !($0 is NSNull) }) == true {
            guard event else { throw MobileHelperError.upstreamRejected }
            return try HTTPResponseEncoder.makeJSONEncoder().encode(HelperChatStreamEvent.failure("The helper could not complete this request."))
        }
        for token in [accountToken, deviceToken].compactMap({ $0 }) {
            // JSON escapes must not bypass credential checks (including nested strings/keys).
            guard data.range(of: Data(token.utf8)) == nil, !containsCredential(object, token: token) else {
                throw MobileHelperError.upstreamRejected
            }
        }
        return data
    }

    private static func containsCredential(_ value: Any, token: String) -> Bool {
        if let string = value as? String { return string.contains(token) }
        if let array = value as? [Any] { return array.contains { containsCredential($0, token: token) } }
        if let fields = value as? [String: Any] {
            return fields.contains { $0.key.contains(token) || containsCredential($0.value, token: token) }
        }
        return false
    }

    static func request(_ request: HTTPRequest, origin: URL) throws -> URLRequest {
        let path: String
        switch request.path {
        case "/v1/claude/models": path = "auth/claude-code/models"
        case "/v1/claude/chat/completions": path = "account/chat/completions"
        default: throw MobileHelperError.upstreamRejected
        }
        guard let token = request.headers["x-langtools-account-token"], !token.isEmpty,
              token.utf8.count <= 8192,
              token.utf8.allSatisfy({ (33...126).contains($0) }),
              token != request.authorizationBearerToken else { throw MobileHelperError.invalidPairing }
        var upstream = URLRequest(url: try validatedOrigin(origin).appendingPathComponent(path))
        upstream.httpMethod = request.method
        upstream.httpBody = request.method == "POST" ? request.body : nil
        upstream.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Do not copy any incoming headers: device auth, account-token, cookies, and hop-by-hop headers stay local.
        return upstream
    }
}
