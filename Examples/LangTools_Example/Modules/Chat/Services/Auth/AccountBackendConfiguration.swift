import Foundation

public struct AccountBackendConfiguration: Equatable {
    public static let callbackScheme = "langtools-example-auth"
    public static let callbackHost = "auth"

    public let baseURL: URL

    public init(baseURL: URL = UserDefaults.accountBackendBaseURL) {
        self.baseURL = baseURL
    }

    public func callbackURL(for provider: AccountLoginProvider) -> URL {
        var components = URLComponents()
        components.scheme = Self.callbackScheme
        components.host = Self.callbackHost
        components.path = "/callback/\(provider.rawValue)"
        guard let url = components.url else {
            preconditionFailure("Failed to build callback URL for \(provider.rawValue)")
        }
        return url
    }

    public func openAILocalhostCallbackURL(port: UInt16, host: String = "127.0.0.1") -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/auth/callback"
        return components.url ?? URL(string: "http://\(host):\(port)/auth/callback")!
    }

    public func loginStartURL(for provider: AccountLoginProvider, state: String) -> URL {
        guard var components = URLComponents(url: baseURL.appending(path: "/auth/\(provider.startPathComponent)/start"), resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: callbackURL(for: provider).absoluteString),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url ?? baseURL
    }

    public func exchangeURL(for provider: AccountLoginProvider) -> URL {
        baseURL.appending(path: "/auth/\(provider.startPathComponent)/exchange")
    }

    public func logoutURL(for provider: AccountLoginProvider) -> URL {
        baseURL.appending(path: "/auth/\(provider.startPathComponent)/logout")
    }

    public func accountChatURL() -> URL {
        baseURL.appending(path: "/account/chat/completions")
    }
}
