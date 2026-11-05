import Foundation
import KeychainAccess
import SwiftUI
import XCTest
@testable import Chat

@MainActor
final class AccessPromptInjectionTests: XCTestCase {
    func testInjectedConstructionIsInertAndRetainsTheOwnedManager() throws {
        let fixture = try AccessPromptFixture()
        let calls = AccessPromptCalls()
        let modelReads = fixture.model.reads
        let context = fixture.context(calls: calls)
        let reads = fixture.keys.reads
        let controller = AccessPromptController(context: context)
        let presentation = AccessPromptPresentation.injected(context)
        guard case .injected(let selected) = presentation else { return XCTFail("Expected owned route") }
        XCTAssertTrue(selected.accessManager === fixture.manager)
        XCTAssertTrue(controller.accessManager === fixture.manager)
        _ = EmptyView().manageAccessPrompts(accessPrompts: context, priority: 10)
        XCTAssertEqual(calls.actions, [])
        XCTAssertEqual(fixture.model.reads, modelReads)
        XCTAssertEqual(fixture.model.writes, 0)
        XCTAssertEqual(fixture.keys.reads, reads)
        XCTAssertEqual(fixture.secrets.values, [:])
        XCTAssertEqual(fixture.credentials.operations, 0)
        // No legacy modifier, whole settings/VM or login coordinator actions are invoked.
    }

    func testKeySaveValidationRemovalAndSerperUseOwnedOperations() throws {
        let fixture = try AccessPromptFixture()
        let other = try AccessPromptFixture()
        let calls = AccessPromptCalls()
        let controller = AccessPromptController(context: fixture.context(calls: calls))
        XCTAssertThrowsError(try controller.saveAPIKey(" \n ", for: .openAI))
        XCTAssertTrue(calls.actions.isEmpty)
        for service in [APIService.openAI, .serper] {
            try controller.saveAPIKey("  fixture-key \n", for: service)
            XCTAssertEqual(fixture.keys.values[service], "fixture-key")
            XCTAssertTrue(fixture.manager.state(for: service).hasAPIKey)
            XCTAssertFalse(other.manager.state(for: service).hasAPIKey)
            try controller.removeAPIKey(for: service)
            XCTAssertFalse(fixture.manager.state(for: service).hasAPIKey)
        }
        XCTAssertEqual(calls.actions, ["save:openAI", "remove:openAI", "save:serper", "remove:serper"])
    }

    func testAccountAndHelperActionsRefreshOwnedStateAndChooseTheCorrectBranch() async throws {
        let fixture = try AccessPromptFixture()
        let calls = AccessPromptCalls()
        let controller = AccessPromptController(context: fixture.context(calls: calls))
        let state = try await controller.connectAccount(.claudeCode)
        XCTAssertTrue(state.hasAccountSession)
        XCTAssertEqual(state.accountIdentifier, "fixture")
        try await controller.disconnectAccount(.claudeCode)
        XCTAssertFalse(fixture.manager.state(for: .anthropic).hasAccountSession)
        try await controller.connectCodexHelper()
        XCTAssertEqual(fixture.manager.session(for: .openAI)?.accessToken, CodexSessionMarker.value)
        try await controller.disconnectCodex(usesHelper: true)
        XCTAssertNil(fixture.manager.session(for: .openAI))
        _ = try await controller.connectAccount(.openAI)
        try await controller.disconnectCodex(usesHelper: false)
        XCTAssertNil(fixture.manager.session(for: .openAI))
        XCTAssertEqual(calls.actions, ["connect:claudeCode", "disconnect:claudeCode", "helper-connect",
            "helper-disconnect", "connect:openAI", "disconnect:openAI"])
    }

    func testMutationErrorsPropagateWithoutAdvertisingSuccess() async throws {
        let fixture = try AccessPromptFixture()
        let calls = AccessPromptCalls()
        calls.fail = true
        let controller = AccessPromptController(context: fixture.context(calls: calls))
        XCTAssertThrowsError(try controller.saveAPIKey("fixture", for: .serper))
        XCTAssertThrowsError(try controller.removeAPIKey(for: .openAI))
        do { _ = try await controller.connectAccount(.openAI); XCTFail("Expected error") } catch {}
        do { try await controller.disconnectAccount(.openAI); XCTFail("Expected error") } catch {}
        do { try await controller.connectCodexHelper(); XCTFail("Expected error") } catch {}
        do { try await controller.disconnectCodex(usesHelper: true); XCTFail("Expected error") } catch {}
        XCTAssertEqual(fixture.secrets.values, [:])
        XCTAssertEqual(fixture.keys.values, [:])
        XCTAssertFalse(fixture.manager.state(for: .openAI).hasAccountSession)
    }

    func testInjectedResolutionIsDynamicAndLifecyclePreservesOwnerArbitration() throws {
        let fixture = try AccessPromptFixture()
        let modelReads = fixture.model.reads
        let dependencies = fixture.context(calls: AccessPromptCalls()).resolvePresentationDependencies()
        XCTAssertTrue(dependencies.presentation === fixture.presentation)
        XCTAssertTrue(dependencies.login === fixture.login)
        XCTAssertEqual(fixture.model.reads, modelReads)
        XCTAssertEqual(dependencies.model.wrappedValue.apiService, .openAI)
        fixture.model.value = try XCTUnwrap(Model(rawValue: "ollama/llama3.2"))
        XCTAssertEqual(dependencies.model.wrappedValue.apiService, .ollama)
        XCTAssertNil(AccessDestination.destination(for: dependencies.model.wrappedValue))
        let root = UUID(), settings = UUID()
        fixture.presentation.registerPresenter(root, priority: 0)
        fixture.presentation.registerPresenter(settings, priority: 10)
        XCTAssertEqual(fixture.presentation.presentationOwner, settings)
        fixture.presentation.present(preferredDestination: .anthropic)
        XCTAssertEqual(fixture.presentation.preferredDestination, .anthropic)
        fixture.presentation.dismiss()
        XCTAssertNil(fixture.presentation.preferredDestination)
        XCTAssertFalse(fixture.presentation.isPresented)
        fixture.presentation.unregisterPresenter(settings)
        XCTAssertEqual(fixture.presentation.presentationOwner, root)
        fixture.presentation.unregisterPresenter(root)
        XCTAssertNil(fixture.presentation.presentationOwner)
        XCTAssertEqual(fixture.model.writes, 0)
    }

    func testLegacySelectionDoesNotResolveDependencies() {
        let presentation = AccessPromptPresentation.legacy
        guard case .legacy = presentation else { return XCTFail("Expected legacy selector") }
        // Deliberately never render this route or evaluate the legacy adapter.
    }
}

@MainActor
final class AccessPromptCalls {
    var actions: [String] = []
    var fail = false
    func record(_ action: String) throws {
        actions.append(action)
        if fail { throw AccessPromptFixture.Failure.operation }
    }
}

/// Shared only by F3 suites. No session, transport or production login client is constructed.
@MainActor
final class AccessPromptFixture {
    enum Failure: Error { case operation }
    let suite = "AccessPromptFixture.\(UUID().uuidString)"
    let defaults: UserDefaults
    let secrets = SettingsMemorySecretStore()
    let keys = AccessPromptKeyStore()
    let credentials = AccessPromptCredentialStore()
    let configuration: OllamaEndpointConfiguration
    let manager: ProviderAccessManager
    let model = AccessPromptMemoryModel()
    let selectedModelBinding: Binding<Model>
    let presentation = AuthPresentationCoordinator()
    let login = AccountLoginCoordinator()

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("http://access-fixture.invalid:11434", forKey: OllamaEndpointConfiguration.endpointKey)
        configuration = OllamaEndpointConfiguration(userDefaults: defaults, credentialStore: credentials)
        manager = ProviderAccessManager(keychainService: keys, sessionStore: AuthSessionStore(secretStore: secrets),
            ollamaEndpointConfiguration: configuration)
        // SwiftUI Binding.init samples its getter; do this BEFORE context construction.
        selectedModelBinding = model.binding
    }

    deinit { defaults.removePersistentDomain(forName: suite) }

    func context(calls: AccessPromptCalls) -> AccessPromptContext {
        AccessPromptContext(accessManager: manager, saveAPIKey: { [self] key, service in
            try calls.record("save:\(service)")
            keys.values[service] = key
        }, removeAPIKey: { [self] service in
            try calls.record("remove:\(service)")
            keys.values.removeValue(forKey: service)
        }, connectAccount: { [self] provider in
            try calls.record("connect:\(provider.rawValue)")
            // Write directly to the memory store: the controller must refresh the owned manager.
            try AuthSessionStore(secretStore: secrets).save(AccountSession(provider: provider,
                accountIdentifier: "fixture", accessToken: "fixture", accessibleModelIDs: []))
        }, disconnectAccount: { [self] provider in
            try calls.record("disconnect:\(provider.rawValue)")
            try AuthSessionStore(secretStore: secrets).removeSession(for: provider)
        }, connectCodexHelper: { [self] in
            try calls.record("helper-connect")
            try AuthSessionStore(secretStore: secrets).save(AccountSession(provider: .openAI,
                accountIdentifier: "fixture", accessToken: CodexSessionMarker.value))
        }, disconnectCodexHelper: { [self] in
            try calls.record("helper-disconnect")
            try AuthSessionStore(secretStore: secrets).removeSession(for: .openAI)
        }, selectedModelBinding: selectedModelBinding, presentationCoordinator: presentation, loginCoordinator: login)
    }
}

@MainActor
final class AccessPromptMemoryModel {
    var value: Model = .openAI(.gpt4o_mini)
    private(set) var reads = 0
    private(set) var writes = 0
    var binding: Binding<Model> {
        Binding(get: { self.reads += 1; return self.value }, set: { self.writes += 1; self.value = $0 })
    }
}

final class AccessPromptKeyStore: KeychainService {
    var values: [APIService: String] = [:]
    private(set) var reads = 0
    init() { super.init(keychain: Keychain(service: "AccessPromptKeyStore.inert.\(UUID().uuidString)")) }
    override func getApiKey(for service: APIService) -> String? { reads += 1; return values[service] }
    override func saveApiKey(apiKey: String, for service: APIService) { values[service] = apiKey }
    override func deleteApiKey(for service: APIService) { values.removeValue(forKey: service) }
}

final class AccessPromptCredentialStore: MobileHelperCredentialStoring, @unchecked Sendable {
    private(set) var operations = 0
    func load(helperID: String) throws -> MobileHelperCredential? { operations += 1; return nil }
    func save(_ credential: MobileHelperCredential) throws { operations += 1 }
    func remove(helperID: String) throws { operations += 1 }
}
