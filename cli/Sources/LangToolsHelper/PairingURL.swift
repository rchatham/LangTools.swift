import Foundation

/// Builds one-click pairing URLs for LangTools_Example.
///
/// Contract: `langtools-example-auth://codex-helper/pair?port=<1-65535>&token=<64 hex>`
///
/// The example app validates the URL strictly (scheme, host, path, port range,
/// and token shape) and always shows a confirmation alert before saving, so
/// this is the only URL shape the helper ever opens.
enum PairingURL {
    enum PairingError: LocalizedError, Sendable {
        case invalidPort(UInt16)
        case invalidToken
        case unableToBuildURL

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "The helper port is invalid: \(port)."
            case .invalidToken:
                return "One-click pairing requires a helper token of 64 hexadecimal characters."
            case .unableToBuildURL:
                return "The pairing URL could not be assembled."
            }
        }
    }

    static let scheme = "langtools-example-auth"
    static let host = "codex-helper"
    static let path = "/pair"

    /// Builds the pairing URL for the local helper. Percent-encoding is not
    /// needed for a port or a hex token, but the URL is assembled with
    /// `URLComponents` anyway.
    static func make(port: UInt16, token: String) throws -> URL {
        guard (1...65535).contains(port) else { throw PairingError.invalidPort(port) }
        let hexDigits = Set("0123456789abcdefABCDEF")
        guard token.count == 64, token.allSatisfy(hexDigits.contains) else {
            throw PairingError.invalidToken
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: token)
        ]
        guard let url = components.url else { throw PairingError.unableToBuildURL }
        return url
    }
}