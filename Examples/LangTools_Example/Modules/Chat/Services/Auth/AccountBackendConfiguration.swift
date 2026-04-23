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
        return components.url ?? URL(string: "\(Self.callbackScheme)://\(Self.callbackHost)/callback/\(provider.rawValue)")!
    }

    public func loginStartURL(for provider: AccountLoginProvider, state: String) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "/auth/\(provider.startPathComponent)/start"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: callbackURL(for: provider).absoluteString),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
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
