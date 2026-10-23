import Foundation

/// Account transport is independent of ModelRoute: platform models always use API keys.
public enum AccountTransportChoice: String, CaseIterable, Sendable {
    case existing
    case pairedHelper
}

/// Immutable selection snapshots own the pinned session until the last consumer ends.
/// No URL from UserDefaults is ever accepted as a paired account destination.
public final class AccountTransportSelectionStore: @unchecked Sendable {
    public static let shared = AccountTransportSelectionStore()
    static let didChange = Notification.Name("AccountTransportSelectionStore.didChange")

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    public struct Snapshot: Equatable {
        public let provider: AccountLoginProvider
        public let choice: AccountTransportChoice
        public let revision: UInt64
        public let helperID: String?
        public let helperName: String?
        let connection: MobileHelperConnection?
        let error: MobileHelperError?
        let modelIDs: [String]
        let accountIdentifier: String?
        let accountSessionRevision: UInt64?
        public var isPaired: Bool { choice == .pairedHelper }
        public var label: String {
            isPaired ? "LangToolsHelper (\(helperName ?? "disconnected"))" :
                (provider == .openAI ? "Local Codex helper" : "Claude Code backend")
        }
        public static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.provider == rhs.provider && lhs.choice == rhs.choice && lhs.revision == rhs.revision && lhs.helperID == rhs.helperID
        }
        func requireConnection() throws -> MobileHelperConnection {
            if let error { throw error }
            guard isPaired, let connection else { throw MobileHelperError.disconnected }
            try connection.credential.validate()
            let capability = provider == .openAI ? "codex" : "claude"
            guard connection.credential.capabilities.contains(capability) else {
                throw MobileHelperError.missingCapability(capability)
            }
            return connection
        }
        func actionableError(_ error: Error) -> Error {
            guard isPaired else { return error }
            let mapped = MobileHelperError.actionable(error, session: connection?.session)
            if mapped as? MobileHelperError == .ollamaUnavailable { return MobileHelperError.accountUnavailable }
            return mapped
        }
    }

    private struct Selection {
        var choice: AccountTransportChoice = .existing
        var revision: UInt64 = 0
        var helperID: String?
        var helperName: String?
        var connection: MobileHelperConnection?
        var error: MobileHelperError?
        var modelIDs: [String] = []
        var accountIdentifier: String?
        var accountSessionRevision: UInt64?
    }
    private let defaults: UserDefaults
    private let credentials: any MobileHelperCredentialStoring
    private let lock = NSLock()
    private var selections: [AccountLoginProvider: Selection] = [:]
    private var paired: MobileHelperConnection?
    private var pairedError: MobileHelperError?
    private var pairedName: String?
    private static let pairedKey = "accountPairedMobileHelperID"
    private static func key(_ provider: AccountLoginProvider) -> String { "\(provider.rawValue)AccountTransport" }

    public convenience init(userDefaults: UserDefaults = .standard) {
        self.init(userDefaults: userDefaults, credentialStore: MobileHelperCredentialStore.shared)
    }
    init(userDefaults: UserDefaults, credentialStore: any MobileHelperCredentialStoring) {
        defaults = userDefaults
        credentials = credentialStore
        pairedName = defaults.string(forKey: "accountPairedMobileHelperName")
        let pairedID = defaults.string(forKey: Self.pairedKey)
        if let pairedID, !defaults.bool(forKey: "accountPairedHelperDisconnected") {
            do {
                if let credential = try credentialStore.load(helperID: pairedID) {
                    try credential.validate()
                    paired = MobileHelperConnection(credential: credential)
                } else { pairedError = .disconnected }
            } catch { pairedError = .persistence(error.localizedDescription) }
        }
        for provider in AccountLoginProvider.allCases {
            let choice = AccountTransportChoice(rawValue: defaults.string(forKey: Self.key(provider)) ?? "") ?? .existing
            var selection = Selection(choice: choice)
            if choice == .pairedHelper {
                selection.helperID = pairedID
                selection.helperName = paired?.credential.name ?? pairedName
                selection.connection = paired
                selection.error = pairedError ?? (paired == nil ? .disconnected : nil)
            }
            selections[provider] = selection
        }
    }

    public func snapshot(for provider: AccountLoginProvider) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked(for: provider)
    }
    private func snapshotLocked(for provider: AccountLoginProvider) -> Snapshot {
        let value = selections[provider] ?? Selection()
        return Snapshot(provider: provider, choice: value.choice, revision: value.revision,
            helperID: value.helperID, helperName: value.helperName, connection: value.connection,
            error: value.error, modelIDs: value.modelIDs, accountIdentifier: value.accountIdentifier, accountSessionRevision: value.accountSessionRevision)
    }
    public func isCurrent(_ snapshot: Snapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot == snapshotLocked(for: snapshot.provider)
    }
    /// Registration exists before any provider is selected. Disconnect must
    /// retire it too, or a later selection could revive a removed device token.
    public var registeredHelperID: String? {
        lock.lock(); defer { lock.unlock() }
        return defaults.string(forKey: Self.pairedKey)
    }

    public var pairedHelperLabel: String {
        lock.lock(); defer { lock.unlock() }
        return "LangToolsHelper (\(paired?.credential.name ?? pairedName ?? "not paired"))"
    }

    /// Pairing records a verified connection, but never switches an account route.
    func registerPairedHelper(_ connection: MobileHelperConnection, persistCredential: Bool = true) throws {
        try connection.credential.validate()
        if persistCredential { try credentials.save(connection.credential) }
        lock.lock(); defer { lock.unlock(); notify() }
        paired = connection
        pairedError = nil
        pairedName = connection.credential.name
        defaults.set(false, forKey: "accountPairedHelperDisconnected")
        defaults.set(connection.credential.helperID, forKey: Self.pairedKey)
        defaults.set(pairedName, forKey: "accountPairedMobileHelperName")
        for provider in AccountLoginProvider.allCases where selections[provider]?.choice == .pairedHelper {
            var value = selections[provider] ?? Selection()
            value.connection = connection
            value.helperID = connection.credential.helperID
            value.helperName = pairedName
            value.error = nil
            value.modelIDs = []
            value.accountIdentifier = nil
            value.revision &+= 1
            selections[provider] = value
        }
    }

    public func select(_ choice: AccountTransportChoice, for provider: AccountLoginProvider) {
        lock.lock(); defer { lock.unlock(); notify() }
        var value = selections[provider] ?? Selection()
        value.choice = choice
        value.revision &+= 1
        value.modelIDs = []
        value.accountIdentifier = nil
        value.connection = choice == .pairedHelper ? paired : nil
        value.helperID = choice == .pairedHelper ? defaults.string(forKey: Self.pairedKey) : nil
        value.helperName = choice == .pairedHelper ? paired?.credential.name ?? pairedName : nil
        value.error = choice == .pairedHelper ? pairedError ?? (paired == nil ? .disconnected : nil) : nil
        selections[provider] = value
        defaults.set(choice.rawValue, forKey: Self.key(provider))
    }

    /// Clears future routes/catalogs only; captured requests retain their own lease.
    public func disconnectHelper() throws {
        lock.lock(); defer { lock.unlock(); notify() }
        var removalError: Error?
        if let id = defaults.string(forKey: Self.pairedKey) {
            do { try credentials.remove(helperID: id) } catch { removalError = error }
        }
        defaults.set(true, forKey: "accountPairedHelperDisconnected")
        paired = nil
        pairedError = .disconnected
        for provider in AccountLoginProvider.allCases where selections[provider]?.choice == .pairedHelper {
            var value = selections[provider] ?? Selection()
            value.connection = nil
            value.error = .disconnected
            value.modelIDs = []
            value.accountIdentifier = nil
            value.revision &+= 1
            selections[provider] = value
        }
        if let removalError { throw removalError }
    }

    @discardableResult
    func publish(modelIDs: [String], accountIdentifier: String?, for snapshot: Snapshot, accountSessionRevision: UInt64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock(); notify() }
        guard snapshot == snapshotLocked(for: snapshot.provider), snapshot.isPaired else { return false }
        var value = selections[snapshot.provider] ?? Selection()
        value.modelIDs = modelIDs
        value.accountIdentifier = accountIdentifier
        value.accountSessionRevision = accountSessionRevision
        value.error = nil
        selections[snapshot.provider] = value
        return true
    }
    @discardableResult
    func fail(_ error: Error, for snapshot: Snapshot) -> Bool {
        lock.lock(); defer { lock.unlock(); notify() }
        guard snapshot == snapshotLocked(for: snapshot.provider), snapshot.isPaired else { return false }
        var value = selections[snapshot.provider] ?? Selection()
        value.modelIDs = []
        value.accountIdentifier = nil
        value.error = snapshot.actionableError(error) as? MobileHelperError ?? .accountUnavailable
        value.revision &+= 1
        selections[snapshot.provider] = value
        return true
    }

    /// Retry can reuse the trusted connection; it must never change transport.
    func discoverySnapshot(for provider: AccountLoginProvider) -> Snapshot {
        lock.lock(); defer { lock.unlock(); notify() }
        var value = selections[provider] ?? Selection()
        if value.choice == .pairedHelper, value.connection != nil {
            value.error = nil
            value.modelIDs = []
            value.accountIdentifier = nil
            value.revision &+= 1
            selections[provider] = value
        }
        return snapshotLocked(for: provider)
    }
}
