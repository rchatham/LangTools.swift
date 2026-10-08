import XCTest
import KeychainAccess
import Ollama
@testable import Chat

/// `OllamaEndpointPolicy` is the fail-closed endpoint policy used by Botsworth's
/// startup discovery and backend routing. The shared app stack (OllamaService,
/// OllamaSettingsView, NetworkClient) now routes through OllamaEndpointConfiguration
/// (upstream main semantics: invalid persisted values reset to the default
/// endpoint); its behavior is covered by OllamaEndpointConfigurationTests,
/// OllamaEndpointRoutingTests, and OllamaAppRegressionTests. This suite pins the
/// policy itself plus the settings view's never-echo-secrets guarantee.
final class OllamaEndpointPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OllamaEndpointPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAbsentSettingUsesDefaultAndFactoryUsesLoopbackSession() throws {
        XCTAssertEqual(try OllamaEndpointPolicy.resolve(userDefaults: defaults), OllamaEndpointPolicy.defaultURL)

        let ollama = try OllamaEndpointPolicy.makeOllama(userDefaults: defaults)

        XCTAssertEqual(ollama.configuration.baseURL, URL(string: "http://localhost:11434"))
        XCTAssertTrue(ollama.session === LoopbackURLSession.shared)
    }

    func testValidEndpointsPreserveCustomPath() throws {
        let values = [
            "http://localhost:22445/custom/path",
            "http://127.0.0.1:22445/custom/path",
            "http://[::1]:22445/custom/path",
            "https://ollama.example.com/custom/path",
        ]

        for value in values {
            XCTAssertEqual(try OllamaEndpointPolicy.validate(value).absoluteString, value)
        }
    }

    func testPresentInvalidEndpointsNeverFallBackToDefault() {
        let invalidValues: [(String, OllamaEndpointError)] = [
            ("", .empty),
            (" https://ollama.example.com", .malformed(" https://ollama.example.com")),
            ("not a url", .unsupportedScheme(nil)),
            ("localhost:11434", .unsupportedScheme("localhost")),
            ("ftp://localhost:11434", .unsupportedScheme("ftp")),
            ("https:///missing-host", .missingHost),
            ("https://user@ollama.example.com/path", .disallowedComponent("user or password")),
            ("https://user:password@ollama.example.com/path", .disallowedComponent("user or password")),
            ("https://ollama.example.com/path?model=one", .disallowedComponent("query")),
            ("https://ollama.example.com/path?", .disallowedComponent("query")),
            ("https://ollama.example.com/path#models", .disallowedComponent("fragment")),
            ("https://ollama.example.com/path#", .disallowedComponent("fragment")),
            ("http://example.com:11434", .unsafeHTTPHost("example.com")),
            ("http://localhost.example.com:11434", .unsafeHTTPHost("localhost.example.com")),
        ]

        for (value, expectedError) in invalidValues {
            defaults.set(value, forKey: OllamaEndpointPolicy.userDefaultsKey)
            XCTAssertThrowsError(try OllamaEndpointPolicy.resolve(userDefaults: defaults), value) { error in
                XCTAssertEqual(error as? OllamaEndpointError, expectedError)
            }
        }

        defaults.set(11434, forKey: OllamaEndpointPolicy.userDefaultsKey)
        XCTAssertThrowsError(try OllamaEndpointPolicy.resolve(userDefaults: defaults)) { error in
            guard case .malformed = error as? OllamaEndpointError else {
                return XCTFail("Expected malformed error, got \(error)")
            }
        }
    }

    @MainActor
    func testSettingsDisplayCanonicalEndpointAndNeverEchoInvalidLegacySecrets() throws {
        // A valid persisted endpoint displays unchanged.
        defaults.set("https://ollama.example.com", forKey: OllamaEndpointConfiguration.endpointKey)
        let keychain = Keychain(service: "OllamaEndpointPolicyTests.\(UUID().uuidString)")
        let manager = ProviderAccessManager(
            keychainService: KeychainService(keychain: keychain),
            sessionStore: AuthSessionStore(keychain: keychain)
        )
        let service = OllamaService(
            endpointConfiguration: OllamaEndpointConfiguration(userDefaults: defaults),
            providerAccessManager: manager
        )
        let settings = OllamaSettingsView.ViewModel(ollamaService: service)
        XCTAssertEqual(settings.serverUrl, "https://ollama.example.com")
        XCTAssertEqual(settings.editingServerUrl, "https://ollama.example.com")

        // Invalid legacy secret-bearing values follow the upstream shared-stack
        // semantics: they reset to the default endpoint and are never echoed in
        // published UI state or validation errors.
        let invalidValues = [
            "https://user:secret@ollama.example.com/path",
            "https://ollama.example.com/path?token=secret",
            "https://ollama.example.com/path#secret",
            "secret://ollama.example.com/path",
        ]

        for value in invalidValues {
            defaults.set(value, forKey: OllamaEndpointConfiguration.endpointKey)
            let configuration = OllamaEndpointConfiguration(userDefaults: defaults)
            XCTAssertEqual(
                configuration.directBaseURL,
                OllamaEndpointConfiguration.defaultBaseURL,
                "invalid persisted value must reset to the default endpoint: \(value)"
            )
            XCTAssertEqual(
                defaults.string(forKey: OllamaEndpointConfiguration.endpointKey),
                OllamaEndpointConfiguration.defaultBaseURL.absoluteString,
                "the reset must be persisted so the legacy value is discarded: \(value)"
            )

            let settings = OllamaSettingsView.ViewModel(ollamaService: OllamaService(
                endpointConfiguration: configuration,
                providerAccessManager: manager
            ))
            XCTAssertEqual(settings.serverUrl, OllamaEndpointConfiguration.defaultBaseURL.absoluteString, value)
            XCTAssertEqual(settings.editingServerUrl, OllamaEndpointConfiguration.defaultBaseURL.absoluteString, value)

            settings.editingServerUrl = value
            XCTAssertFalse(settings.updateServerUrl(), value)
            let validationError = try XCTUnwrap(settings.endpointValidationError, value)
            XCTAssertFalse(validationError.contains("secret"), value)

            settings.editingServerUrl = "http://127.0.0.1:11434"
            XCTAssertTrue(settings.updateServerUrl())
            XCTAssertEqual(settings.serverUrl, "http://127.0.0.1:11434")
            XCTAssertEqual(
                defaults.string(forKey: OllamaEndpointConfiguration.endpointKey),
                "http://127.0.0.1:11434"
            )
        }

        try? keychain.removeAll()
    }
}
