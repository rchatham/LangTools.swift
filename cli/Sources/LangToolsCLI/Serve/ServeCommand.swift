import Foundation

struct ServeCommand {
    static func run(arguments: [String]) async throws {
        let options = try ServeOptions(arguments: arguments)
        let token = options.token ?? randomToken()
        let server = LocalHelperServer(host: options.host, port: options.port, bearerToken: token)
        try await server.run()
    }

    private static func randomToken() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct ServeOptions {
    let host: String
    let port: UInt16
    let token: String?

    init(arguments: [String]) throws {
        self.host = Self.optionalValue(for: "--host", in: arguments) ?? "127.0.0.1"
        if let portValue = Self.optionalValue(for: "--port", in: arguments) {
            guard let port = UInt16(portValue), port > 0 else {
                throw ServeOptionsError.invalidPort(portValue)
            }
            self.port = port
        } else {
            self.port = 8765
        }
        self.token = Self.optionalValue(for: "--token", in: arguments)
    }

    private static func optionalValue(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

enum ServeOptionsError: LocalizedError {
    case invalidPort(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let value):
            return "Invalid helper port: \(value)"
        }
    }
}
