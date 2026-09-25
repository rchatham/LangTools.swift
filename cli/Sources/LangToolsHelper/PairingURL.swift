import Foundation

/// Builds one-click pairing URLs for LangTools_Example.
///
/// Contract: `langtools-example-auth://codex-helper/pair?port=<1-65535>&code=<64 hex>`
///
/// The URL carries a short-lived, single-use pairing code — never the long-lived
/// helper bearer token. The example app validates the URL strictly (scheme,
/// host, path, port range, and code shape) and always shows a confirmation
/// alert before exchanging the code for a token over loopback HTTP.
enum PairingURL {
    enum PairingError: LocalizedError, Sendable {
        case invalidPort(UInt16)
        case invalidCode
        case unableToBuildURL

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "The helper port is invalid: \(port)."
            case .invalidCode:
                return "One-click pairing requires a pairing code of 64 hexadecimal characters."
            case .unableToBuildURL:
                return "The pairing URL could not be assembled."
            }
        }
    }

    static let scheme = "langtools-example-auth"
    static let host = "codex-helper"
    static let path = "/pair"

    /// Builds the pairing URL for the local helper. Percent-encoding is not
    /// needed for a port or a hex code, but the URL is assembled with
    /// `URLComponents` anyway.
    static func make(port: UInt16, code: String) throws -> URL {
        guard (1...65535).contains(port) else { throw PairingError.invalidPort(port) }
        let hexDigits = Set("0123456789abcdefABCDEF")
        guard code.count == 64, code.allSatisfy(hexDigits.contains) else {
            throw PairingError.invalidCode
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code", value: code)
        ]
        guard let url = components.url else { throw PairingError.unableToBuildURL }
        return url
    }
}