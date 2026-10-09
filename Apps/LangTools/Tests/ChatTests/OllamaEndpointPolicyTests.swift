import XCTest
import Ollama
@testable import Chat

/// Both compatibility policy and shared configuration enforce one fail-closed validator.
final class OllamaEndpointPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OllamaEndpointPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAbsentSettingUsesDefaultAndFactoryUsesLoopbackSession() throws {
        XCTAssertEqual(try OllamaEndpointPolicy.resolve(userDefaults: defaults), OllamaEndpointPolicy.defaultURL)
        let ollama = try OllamaEndpointPolicy.makeOllama(userDefaults: defaults)
        XCTAssertEqual(ollama.configuration.baseURL, URL(string: "http://localhost:11434"))
        XCTAssertTrue(ollama.session === LoopbackURLSession.shared)
    }

    func testValidEndpointsPreserveCustomPath() throws {
        for value in ["http://localhost:22445/custom/path", "http://127.0.0.1:22445/custom/path", "http://[::1]:22445/custom/path", "https://ollama.example.com/custom%20path"] {
            XCTAssertEqual(try OllamaEndpointPolicy.validate(value).absoluteString, value)
        }
    }

    func testPresentInvalidEndpointsNeverFallBackOrRetainInputInError() {
        let invalidValues = ["", "not a url", "localhost:11434", "ftp://localhost:11434", "https:///missing-host", "https://user:secret@ollama.example.com/path", "https://ollama.example.com/path?secret", "https://ollama.example.com/path#secret", "http://example.com:11434", "http://localhost.example.com:11434"]
        for value in invalidValues {
            defaults.set(value, forKey: OllamaEndpointPolicy.userDefaultsKey)
            XCTAssertThrowsError(try OllamaEndpointPolicy.resolve(userDefaults: defaults)) { error in
                XCTAssertNotNil(error as? OllamaEndpointConfiguration.ValidationError)
                XCTAssertFalse(String(describing: error).contains("secret"))
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
            XCTAssertEqual(defaults.string(forKey: OllamaEndpointPolicy.userDefaultsKey), value)
        }
        defaults.set(11434, forKey: OllamaEndpointPolicy.userDefaultsKey)
        XCTAssertThrowsError(try OllamaEndpointPolicy.resolve(userDefaults: defaults)) { error in
            XCTAssertEqual(error as? OllamaEndpointConfiguration.ValidationError, .invalidURL)
        }
    }

    @MainActor
    func testSettingsDisplayCanonicalEndpointAndNeverEchoInvalidLegacySecrets() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PolicyFailClosedURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        defaults.set("https://ollama.example.com", forKey: OllamaEndpointConfiguration.endpointKey)
        let configuration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: OllamaMemoryHelperStore(), directSession: session)
        let manager = ProviderAccessManager(keychainService: OllamaMemoryKeychainService(), sessionStore: AuthSessionStore(secretStore: OllamaMemorySecrets()), ollamaEndpointConfiguration: configuration)
        let service = OllamaService(endpointConfiguration: configuration, session: session, providerAccessManager: manager)
        let settings = OllamaSettingsView.ViewModel(ollamaService: service)
        XCTAssertEqual(settings.serverUrl, "https://ollama.example.com")
        XCTAssertEqual(settings.editingServerUrl, "https://ollama.example.com")
        for value in ["https://user:secret@ollama.example.com/path", "https://ollama.example.com/path?token=secret", "https://ollama.example.com/path#secret", "secret://ollama.example.com/path"] {
            defaults.set(value, forKey: OllamaEndpointConfiguration.endpointKey)
            let configuration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: OllamaMemoryHelperStore(), directSession: session)
            XCTAssertNil(configuration.directBaseURL)
            XCTAssertEqual(defaults.string(forKey: OllamaEndpointConfiguration.endpointKey), value)
            let settings = OllamaSettingsView.ViewModel(ollamaService: OllamaService(endpointConfiguration: configuration, session: session, providerAccessManager: manager))
            XCTAssertEqual(settings.serverUrl, "")
            XCTAssertEqual(settings.editingServerUrl, "")
            XCTAssertNotNil(settings.endpointValidationError)
            settings.editingServerUrl = value
            XCTAssertFalse(settings.updateServerUrl())
            XCTAssertFalse(try XCTUnwrap(settings.endpointValidationError).contains("secret"))
            settings.editingServerUrl = "http://127.0.0.1:11434"
            XCTAssertTrue(settings.updateServerUrl())
            XCTAssertEqual(settings.serverUrl, "http://127.0.0.1:11434")
            XCTAssertNil(settings.endpointValidationError)
            XCTAssertEqual(defaults.string(forKey: OllamaEndpointConfiguration.endpointKey), "http://127.0.0.1:11434")
        }
    }
}

/// Synthetic failure for every request; never falls through to real transport.
private final class PolicyFailClosedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
