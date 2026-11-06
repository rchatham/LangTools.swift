import Foundation

/// The SDK's account mutation policy, bound to an explicit access graph.
/// Resolving login services is deferred until an operation is requested.
public final class ProviderAccountAccessOperations {
    private let providerAccessManager: ProviderAccessManager
    private let loginServiceProvider: @MainActor () -> any AccountLoginService

    public init(
        providerAccessManager: ProviderAccessManager,
        loginServiceProvider: @escaping @MainActor () -> any AccountLoginService
    ) {
        self.providerAccessManager = providerAccessManager
        self.loginServiceProvider = loginServiceProvider
    }

    public func connectAccount(_ provider: AccountLoginProvider) async throws {
        let session = try await loginServiceProvider().beginLogin(for: provider)
        try await MainActor.run {
            try providerAccessManager.saveAccountSession(session)
        }
    }

    public func connectCodexHelper() async throws {
        let session = try await loginServiceProvider().beginCodexHelperLogin()
        try await MainActor.run {
            try providerAccessManager.saveAccountSession(session.canonicalized)
        }
    }

    public func disconnectAccount(_ provider: AccountLoginProvider) async throws {
        let sessionBeingDisconnected = providerAccessManager.session(for: provider)
        if provider == .openAI,
           sessionBeingDisconnected?.accessToken == CodexSessionMarker.value {
            try await disconnectCodexHelper()
            return
        }

        do {
            try await loginServiceProvider().logout(provider: provider)
        } catch {
            // A remote logout failure must not leave a stale local session behind.
            NSLog("Remote %@ logout failed; clearing the local session: %@", provider.displayName, error.localizedDescription)
        }
        try await MainActor.run {
            guard providerAccessManager.session(for: provider)?.id == sessionBeingDisconnected?.id else {
                return
            }
            try providerAccessManager.removeAccountSession(for: provider)
        }
    }

    public func disconnectCodexHelper() async throws {
        let sessionBeingDisconnected = providerAccessManager.session(for: .openAI)
        do {
            try await loginServiceProvider().logoutCodexHelper()
        } catch {
            // Keep the local marker from advertising a helper session that can no longer be used.
            NSLog("Remote Codex helper logout failed; clearing the local session: %@", error.localizedDescription)
        }
        try await MainActor.run {
            guard let sessionBeingDisconnected,
                  sessionBeingDisconnected.accessToken == CodexSessionMarker.value,
                  providerAccessManager.session(for: .openAI)?.id == sessionBeingDisconnected.id
            else {
                return
            }
            try providerAccessManager.removeAccountSession(for: .openAI)
        }
    }
}
