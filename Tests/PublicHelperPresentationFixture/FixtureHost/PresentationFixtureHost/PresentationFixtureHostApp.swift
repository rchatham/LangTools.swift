import Foundation
import SwiftUI
import HelperLink
@testable import Chat

// MARK: - Fixture host app
//
// Minimal, Debug-only SwiftUI app used ONLY as a UI Testing Bundle host for
// PR78's isolated iOS presentation verification. It is NOT LangToolsApp and
// never starts any ordinary app startup path, `.shared` coordinator/settings/
// services, or discovery. It hosts exactly one real production API: the
// `mobileHelperPairingPresentation(coordinator:brandingTitle:)` view modifier
// from `Chat`. `@testable import Chat` (with ENABLE_TESTABILITY, a legitimate
// Debug build setting — not a macro-trust bypass) is used only to construct
// an inert, in-memory `MobileHelperCredentialStoring` and a deny-all-network
// counting session factory, so the UI test can assert zero credential/network
// operations instead of only inferring it indirectly.
//
// Fresh, UUID-suffixed `UserDefaults` suite per launch, verified to have no
// inherited selection BEFORE the configuration is constructed; no Keychain
// access (the injected credential store never touches the real Keychain); no
// real network I/O is possible even on an accidental Confirm tap, because the
// injected session's URLProtocol denies every request. Every fail-closed
// condition below crashes this fixture process on purpose — fail loud and
// closed rather than silently falling back to shared/production state.

@main
struct PresentationFixtureHostApp: App {
    var body: some Scene {
        WindowGroup {
            FixtureRootView()
        }
    }
}

enum FixtureScenario: String {
    case defaultTitle
    case customTitle
    case invalid
}

// MARK: - Fail-closed environment resolution

enum FixtureHostError: Error, CustomStringConvertible {
    case notDebugBuild
    case wrongBundle(String)
    case missingScenario
    case unrecognizedScenario(String)
    case freshDefaultsSuiteUnavailable(String)
    case inheritedSelectionPresent(String)

    var description: String {
        switch self {
        case .notDebugBuild:
            return "PresentationFixtureHost must only run in a Debug build."
        case .wrongBundle(let id):
            return "PresentationFixtureHost launched under an unexpected bundle identifier: \(id)"
        case .missingScenario:
            return "FIXTURE_SCENARIO launch environment value is missing."
        case .unrecognizedScenario(let raw):
            return "FIXTURE_SCENARIO value is not recognized: \(raw)"
        case .freshDefaultsSuiteUnavailable(let suite):
            return "Could not create a fresh UserDefaults suite: \(suite)"
        case .inheritedSelectionPresent(let suite):
            return "Fresh UserDefaults suite unexpectedly has an inherited helper selection: \(suite)"
        }
    }
}

/// Pure-policy resolver (mirrors the production `ChatUITestEnvironment`
/// pattern): accepts all inputs explicitly so the fail-closed logic itself is
/// reviewable and so a mistaken relaxation here is a conspicuous one-line
/// diff, not a buried fallback.
enum FixtureEnvironment {
    /// The only bundle identifier this fixture host may run under.
    static let expectedBundleIdentifier = "com.reidchatham.pr78fixture.PresentationFixtureHost"

    static func resolveScenario(rawValue: String?, bundleIdentifier: String, isDebug: Bool) throws -> FixtureScenario {
        guard isDebug else { throw FixtureHostError.notDebugBuild }
        guard bundleIdentifier == expectedBundleIdentifier else {
            throw FixtureHostError.wrongBundle(bundleIdentifier)
        }
        guard let rawValue, !rawValue.isEmpty else { throw FixtureHostError.missingScenario }
        guard let scenario = FixtureScenario(rawValue: rawValue) else {
            throw FixtureHostError.unrecognizedScenario(rawValue)
        }
        return scenario
    }
}

// MARK: - Inert credential store

/// Inert, in-memory credential store: never reads/writes/deletes the real
/// Keychain. Counts are exposed read-only for diagnostic assertions.
final class CountingCredentialStore: MobileHelperCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _loadCount = 0
    private var _saveCount = 0
    private var _removeCount = 0
    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return _loadCount }
    var saveCount: Int { lock.lock(); defer { lock.unlock() }; return _saveCount }
    var removeCount: Int { lock.lock(); defer { lock.unlock() }; return _removeCount }

    func load(helperID: String) throws -> MobileHelperCredential? {
        lock.lock(); _loadCount += 1; lock.unlock()
        return nil
    }
    func save(_ credential: MobileHelperCredential) throws {
        lock.lock(); _saveCount += 1; lock.unlock()
    }
    func remove(helperID: String) throws {
        lock.lock(); _removeCount += 1; lock.unlock()
    }
}

// MARK: - Deny-all network session (defense in depth against an accidental Confirm tap)

enum FixtureNetworkError: LocalizedError {
    case deniedByFixture
    var errorDescription: String? {
        "Fixture URLProtocol denied this request: the presentation fixture must never perform real network I/O, even on an accidental Confirm tap."
    }
}

/// Intercepts and fails every request unconditionally. Installed as the
/// *only* protocol class on the fixture's session configuration, with
/// caching/cookies/credential storage disabled, so even an accidental
/// Confirm tap cannot reach a real network destination.
final class FixtureDenyAllURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canInit(with task: URLSessionTask) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: FixtureNetworkError.deniedByFixture)
    }
    override func stopLoading() {}
}

/// Counts session-factory invocations and returns a session whose transport
/// is fully denied by `FixtureDenyAllURLProtocol`, with cache/cookie/credential
/// storage disabled. Only ever invoked from inside `confirm(...)`, which this
/// fixture never calls — this is defense in depth, not the primary guarantee.
final class SessionFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

    func makeSession(endpoint: URL, fingerprint: String) -> URLSession {
        lock.lock(); _callCount += 1; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureDenyAllURLProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}

final class SelectionCounter: ObservableObject {
    @Published private(set) var value = 0
    func increment() { value += 1 }
}

@MainActor
final class FixtureModel: ObservableObject {
    let scenario: FixtureScenario
    let scheme: String
    let title: String
    let suite: String
    let defaults: UserDefaults
    let credentialStore: CountingCredentialStore
    let sessionCounter: SessionFactoryCounter
    let selectionCounter: SelectionCounter
    let configuration: OllamaEndpointConfiguration
    let coordinator: MobileHelperPairingCoordinator
    let initialHelperID: String?
    let initialRevision: UInt64

    /// Bumped only by the fixture-only "Refresh Diagnostics" control. Forces
    /// a SwiftUI body re-evaluation so the diagnostic `Text` views re-read
    /// `credentialStore`/`sessionCounter`/`configuration.snapshot()` (none of
    /// which are themselves `@Published`) instead of showing values cached
    /// from the view's initial render. Never touches coordinator/UI state and
    /// never re-runs `.task` (a plain `.task { }` only reruns when the view's
    /// identity is recreated, not on an unrelated `@Published` change).
    @Published private(set) var diagnosticsRefreshTick = 0
    func refreshDiagnostics() { diagnosticsRefreshTick += 1 }

    init() {
        do {
            #if DEBUG
            let isDebug = true
            #else
            let isDebug = false
            #endif
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            let rawScenario = ProcessInfo.processInfo.environment["FIXTURE_SCENARIO"]
            let resolvedScenario = try FixtureEnvironment.resolveScenario(
                rawValue: rawScenario, bundleIdentifier: bundleID, isDebug: isDebug)
            scenario = resolvedScenario

            let resolvedScheme: String
            let resolvedTitle: String
            switch resolvedScenario {
            case .defaultTitle:
                resolvedScheme = "langtools-example-auth"
                resolvedTitle = "Connect LangToolsHelper"
            case .customTitle, .invalid:
                resolvedScheme = "botsworth"
                resolvedTitle = "Connect Botsworth Helper"
            }
            scheme = resolvedScheme
            title = resolvedTitle

            let suiteName = "PresentationFixtureHost.\(UUID().uuidString)"
            suite = suiteName
            // FORBIDDEN: falling back to `.standard` on a nil suite would
            // silently expose the real device-wide defaults domain. Fail
            // closed instead.
            guard let resolvedDefaults = UserDefaults(suiteName: suiteName) else {
                throw FixtureHostError.freshDefaultsSuiteUnavailable(suiteName)
            }
            // Assert no inherited selection BEFORE constructing the
            // configuration, so construction itself never has a reason to
            // read Keychain-equivalent state for an existing helper.
            guard resolvedDefaults.string(forKey: OllamaEndpointConfiguration.helperSelectionKey) == nil else {
                throw FixtureHostError.inheritedSelectionPresent(suiteName)
            }
            defaults = resolvedDefaults

            let store = CountingCredentialStore()
            let counter = SessionFactoryCounter()
            let selCounter = SelectionCounter()
            credentialStore = store
            sessionCounter = counter
            selectionCounter = selCounter

            // Internal (non-public) initializer, reachable only via
            // `@testable import Chat`: injects the inert credential store
            // instead of `MobileHelperCredentialStore.shared` (real Keychain).
            let config = OllamaEndpointConfiguration(userDefaults: resolvedDefaults, credentialStore: store)
            configuration = config
            initialHelperID = config.snapshot().helperID
            initialRevision = config.snapshot().revision

            // Internal (non-public) initializer, reachable only via
            // `@testable import Chat`: injects a counting, deny-all-network
            // session factory instead of the real
            // `MobileHelperSessionDelegate.session`. Never invoked unless
            // `confirm(...)` is called, which this fixture never calls.
            let client = MobileHelperPairingClient(sessionFactory: counter.makeSession)
            coordinator = try MobileHelperPairingCoordinator(configuration: config, scheme: resolvedScheme,
                client: client, didSelect: { selCounter.increment() })
        } catch {
            preconditionFailure("PresentationFixtureHost fail-closed: \(error)")
        }
    }

    func triggerScenario() {
        switch scenario {
        case .defaultTitle, .customTitle:
            guard let endpoint = URL(string: "https://192.168.255.254:8086") else {
                preconditionFailure("Invalid synthetic fixture endpoint")
            }
            let payload = MobileHelperPairingPayload(
                endpoint: endpoint,
                helperID: "11111111-1111-4111-8111-111111111111",
                fingerprint: String(repeating: "a", count: 64),
                code: String(repeating: "b", count: 64),
                name: "Synthetic Verification iPhone")
            do {
                coordinator.handle(try payload.pairingURL(scheme: scheme))
            } catch {
                preconditionFailure("Invalid synthetic fixture payload: \(error)")
            }
        case .invalid:
            guard let url = URL(string: "\(scheme)://helper/pair?invalid=1") else {
                preconditionFailure("Invalid fixture failure-scenario URL")
            }
            coordinator.handle(url)
        }
    }
}

struct FixtureRootView: View {
    @StateObject private var model = FixtureModel()

    var body: some View {
        VStack(spacing: 8) {
            Text("Presentation Fixture Host")
                .font(.headline)
                .accessibilityIdentifier("fixture-root-label")
            // Fixture-only control: not a replica of, and never embedded in,
            // the real production sheet/alert. Re-renders the diagnostic
            // labels below so they are read fresh at the moment the UI test
            // taps it, rather than relying on values cached at first render.
            Button("Refresh Diagnostics") { model.refreshDiagnostics() }
                .accessibilityIdentifier("fixture-refresh-diagnostics")
            Group {
                Text("selections:\(model.selectionCounter.value)")
                    .accessibilityIdentifier("diagnostic-selections")
                Text("loadCount:\(model.credentialStore.loadCount)")
                    .accessibilityIdentifier("diagnostic-load-count")
                Text("saveCount:\(model.credentialStore.saveCount)")
                    .accessibilityIdentifier("diagnostic-save-count")
                Text("removeCount:\(model.credentialStore.removeCount)")
                    .accessibilityIdentifier("diagnostic-remove-count")
                Text("sessionCount:\(model.sessionCounter.callCount)")
                    .accessibilityIdentifier("diagnostic-session-count")
                Text("revision:\(model.configuration.snapshot().revision)")
                    .accessibilityIdentifier("diagnostic-revision")
                Text("helperID:\(model.configuration.snapshot().helperID ?? "nil")")
                    .accessibilityIdentifier("diagnostic-helper-id")
                Text("initialRevision:\(model.initialRevision)")
                    .accessibilityIdentifier("diagnostic-initial-revision")
                Text("initialHelperID:\(model.initialHelperID ?? "nil")")
                    .accessibilityIdentifier("diagnostic-initial-helper-id")
            }
            // Read (not written) so this Group is part of the dependency the
            // compiler sees on `diagnosticsRefreshTick`, guaranteeing a
            // re-evaluation of every Text above when it changes.
            .id(model.diagnosticsRefreshTick)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        // The ONLY production API under test. Not a replica, not a fake
        // Cancel/Confirm action — this is the real modifier from Chat.
        .mobileHelperPairingPresentation(coordinator: model.coordinator, brandingTitle: model.title)
        .task {
            model.triggerScenario()
        }
    }
}
