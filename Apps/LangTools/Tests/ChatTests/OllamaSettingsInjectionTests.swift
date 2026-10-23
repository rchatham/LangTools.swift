import Foundation
import KeychainAccess
import XCTest
@testable import Chat

@MainActor
final class OllamaSettingsInjectionTests: XCTestCase {
    func testSettingsInitializersRemainTypedFunctionReferencesOnly() {
        let legacy: (ChatSettingsView.ViewModel) -> ChatSettingsView = ChatSettingsView.init(viewModel:)
        let injected: (ChatSettingsView.ViewModel, OllamaService) -> ChatSettingsView = ChatSettingsView.init(viewModel:ollamaService:)
        let legacySheet: () -> OllamaSettingsView = OllamaSettingsView.init
        let injectedSheet: (OllamaService, OllamaEndpointConfiguration?) -> OllamaSettingsView = OllamaSettingsView.init
        let ownedAccess: (ChatSettingsView.ViewModel, OllamaService, AccessPromptContext) -> ChatSettingsView = ChatSettingsView.init(viewModel:ollamaService:accessPrompts:)
        _ = (legacy, injected, ownedAccess, legacySheet, injectedSheet)
        // Never construct ChatSettingsView or its ViewModel: other globals are outside this seam.
    }

    func testLegacySelectorIsLazyWithoutResolvingSharedService() {
        let presentation = OllamaSettingsPresentation.legacy
        guard case .legacy = presentation else { return XCTFail("Expected the legacy route") }
        // Deliberately do not call makeView(): legacy presentation retains app defaults.
    }

    func testInjectedSelectorRetainsOwnedServiceAndConstructionIsInert() async throws {
        let suite = "OllamaSettingsInjectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("http://settings-fixture.invalid:11434", forKey: OllamaEndpointConfiguration.endpointKey)
        let credentials = SettingsHelperCredentialStore()
        let configuration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: credentials)
        let secrets = SettingsMemorySecretStore()
        let keys = SettingsAPIKeyStore()
        let manager = ProviderAccessManager(keychainService: keys,
            sessionStore: AuthSessionStore(secretStore: secrets), ollamaEndpointConfiguration: configuration)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SettingsBlockedURLProtocol.self]
        SettingsBlockedURLProtocol.reset()
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let service = OllamaService(endpointConfiguration: configuration, session: session, providerAccessManager: manager)
        let snapshot = configuration.snapshot()
        let persisted = defaults.persistentDomain(forName: suite) as NSDictionary?
        let presentation = OllamaSettingsPresentation.injected(service)
        guard case .injected(let selectedService) = presentation else { return XCTFail("Expected injection") }
        XCTAssertTrue(selectedService === service)
        XCTAssertTrue(selectedService.endpointConfiguration === configuration)

        // Construct only the internal sheet via the same selector used by both platforms.
        _ = presentation.makeView()
        _ = OllamaSettingsView(ollamaService: service)
        await Task.yield()
        XCTAssertEqual(configuration.snapshot(), snapshot)
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, persisted)
        XCTAssertEqual(SettingsBlockedURLProtocol.requestURLs, [])
        XCTAssertEqual(credentials.operations, 0)
        XCTAssertTrue(secrets.values.isEmpty)
        XCTAssertEqual(keys.reads, APIService.allCases.count)

        // Prove the service uses the intercepted session only after an explicit operation.
        try await service.checkConnection()
        XCTAssertEqual(SettingsBlockedURLProtocol.requestURLs.map(\.host), ["settings-fixture.invalid"])
        XCTAssertEqual(SettingsBlockedURLProtocol.requestURLs.map(\.path), ["/api/version"])
        XCTAssertEqual(configuration.snapshot(), snapshot)
    }
}

private final class SettingsAPIKeyStore: KeychainService {
    private var values: [APIService: String] = [:]
    private(set) var reads = 0

    init() {
        // KeychainAccess construction is inert; all operations used by the manager are overridden.
        super.init(keychain: Keychain(service: "SettingsAPIKeyStore.inert.\(UUID().uuidString)"))
    }

    override func getApiKey(for service: APIService) -> String? {
        reads += 1
        return values[service]
    }

    override func saveApiKey(apiKey: String, for service: APIService) { values[service] = apiKey }
    override func deleteApiKey(for service: APIService) { values.removeValue(forKey: service) }
}

private final class SettingsHelperCredentialStore: MobileHelperCredentialStoring, @unchecked Sendable {
    private(set) var operations = 0
    func load(helperID: String) throws -> MobileHelperCredential? { operations += 1; return nil }
    func save(_ credential: MobileHelperCredential) throws { operations += 1 }
    func remove(helperID: String) throws { operations += 1 }
}

/// Intercepts every request; cannot fall through to a real network transport.
private final class SettingsBlockedURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var urls: [URL] = []
    static var requestURLs: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    static func reset() { lock.lock(); defer { lock.unlock() }; urls = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.urls.append(url)
        Self.lock.unlock()
        guard url.host == "settings-fixture.invalid", url.path == "/api/version",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"version\":\"fixture\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
