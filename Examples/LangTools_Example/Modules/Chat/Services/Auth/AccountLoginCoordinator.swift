import Foundation

#if os(iOS) || os(macOS)
import AuthenticationServices
#endif

public enum AccountLoginPhase: Equatable {
    case idle
    case openingBrowser(AccountLoginProvider)
    case waitingForCallback(AccountLoginProvider)
}

@MainActor
public protocol AccountLoginCoordinating: AnyObject {
    func startLogin(at url: URL, callbackScheme: String, provider: AccountLoginProvider) async throws -> URL
    func handleRedirect(_ url: URL)
}

@MainActor
public final class AccountLoginCoordinator: NSObject, ObservableObject, AccountLoginCoordinating {
    public static let shared = AccountLoginCoordinator()

    @Published public private(set) var phase: AccountLoginPhase = .idle

    #if os(iOS) || os(macOS)
    private var authenticationSession: ASWebAuthenticationSession?
    #endif
    private var continuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackScheme: String?

    public var isAuthenticating: Bool {
        phase != .idle
    }

    public var statusMessage: String {
        switch phase {
        case .idle:
            return ""
        case .openingBrowser(let provider):
            return "Opening \(provider.displayName) sign-in…"
        case .waitingForCallback(let provider):
            return "Waiting for \(provider.displayName) sign-in to finish…"
        }
    }

    public override init() {
        super.init()
    }

    public func startLogin(at url: URL, callbackScheme: String, provider: AccountLoginProvider) async throws -> URL {
        if continuation != nil {
            throw AccountLoginError.loginAlreadyInProgress
        }

        phase = .openingBrowser(provider)
        pendingCallbackScheme = callbackScheme

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            #if os(iOS) || os(macOS)
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                Task { @MainActor in
                    if let callbackURL {
                        self.complete(with: .success(callbackURL))
                        return
                    }

                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        self.complete(with: .failure(AccountLoginError.cancelled))
                        return
                    }

                    self.complete(with: .failure(error ?? AccountLoginError.missingCallbackURL))
                }
            }
            session.prefersEphemeralWebBrowserSession = true
            authenticationSession = session
            phase = .waitingForCallback(provider)

            if session.start() == false {
                complete(with: .failure(AccountLoginError.unableToStartBrowserSession))
            }
            #else
            complete(with: .failure(AccountLoginError.unsupportedPlatform))
            #endif
        }
    }

    public func handleRedirect(_ url: URL) {
        guard let pendingCallbackScheme, url.scheme == pendingCallbackScheme else {
            return
        }
        complete(with: .success(url))
    }

    private func complete(with result: Result<URL, Error>) {
        let continuation = self.continuation
        self.continuation = nil
        pendingCallbackScheme = nil
        phase = .idle
        #if os(iOS) || os(macOS)
        authenticationSession?.cancel()
        authenticationSession = nil
        #endif

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}
