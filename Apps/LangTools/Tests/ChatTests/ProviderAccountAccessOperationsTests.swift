import Foundation
import XCTest
@testable import Chat

@MainActor
final class ProviderAccountAccessOperationsTests: XCTestCase {
    func testConstructionIsLazyAndAccountLoginUsesOwnedStore() async throws {
        let fixture = try AccountOperationsFixture()
        XCTAssertEqual(fixture.resolutions, 0)
        XCTAssertEqual(fixture.login.calls, [])
        for provider in AccountLoginProvider.allCases {
            try await fixture.operations.connectAccount(provider)
            XCTAssertEqual(fixture.access.manager.session(for: provider)?.accountIdentifier, "fixture")
        }
        XCTAssertEqual(fixture.resolutions, 2)
        XCTAssertEqual(fixture.login.calls, ["login:openAI", "login:claudeCode"])
    }

    func testHelperLoginCanonicalizesBeforePersistence() async throws {
        let fixture = try AccountOperationsFixture()
        try await fixture.operations.connectCodexHelper()
        let session = try XCTUnwrap(fixture.access.manager.session(for: .openAI))
        XCTAssertEqual(session, fixture.login.helperSession.canonicalized)
        XCTAssertEqual(session.accessToken, CodexSessionMarker.value)
        XCTAssertNotEqual(session.accessToken, fixture.login.helperSession.accessToken)
        XCTAssertNil(session.refreshToken)
        XCTAssertNil(session.idToken)
        XCTAssertNil(session.tokenType)
        XCTAssertNil(session.expiresAt)
        XCTAssertEqual(session.id, fixture.login.helperSession.id)
    }

    func testOrdinaryLogoutOfHelperMarkerUsesHelperOperation() async throws {
        let fixture = try AccountOperationsFixture()
        try fixture.access.manager.saveAccountSession(fixture.login.helperSession.canonicalized)
        try await fixture.operations.disconnectAccount(.openAI)
        XCTAssertEqual(fixture.login.calls, ["helper-logout"])
        XCTAssertNil(fixture.access.manager.session(for: .openAI))
    }

    func testRemoteFailuresStillRemoveLocalSessionsInBothBranches() async throws {
        for helper in [false, true] {
            let fixture = try AccountOperationsFixture()
            let session = helper ? fixture.login.helperSession.canonicalized : fixture.login.accountSession(.claudeCode)
            try fixture.access.manager.saveAccountSession(session)
            fixture.login.failLogout = true
            if helper { try await fixture.operations.disconnectCodexHelper() }
            else { try await fixture.operations.disconnectAccount(.claudeCode) }
            XCTAssertNil(fixture.access.manager.session(for: session.provider))
        }
    }

    func testReplacementDuringSuspendedLogoutSurvivesBothBranches() async throws {
        for helper in [false, true] {
            let fixture = try AccountOperationsFixture()
            let original = helper ? fixture.login.helperSession.canonicalized : fixture.login.accountSession(.openAI)
            try fixture.access.manager.saveAccountSession(original)
            let replacement = fixture.login.accountSession(.openAI)
            let entered = expectation(description: "logout entered")
            let gate = AccountLogoutGate()
            fixture.login.logoutHook = { entered.fulfill(); await gate.wait() }
            let task = Task {
                if helper { try await fixture.operations.disconnectCodexHelper() }
                else { try await fixture.operations.disconnectAccount(.openAI) }
            }
            await fulfillment(of: [entered], timeout: 2)
            try fixture.access.manager.saveAccountSession(replacement)
            gate.release()
            try await task.value
            XCTAssertEqual(fixture.access.manager.session(for: .openAI), replacement)
            XCTAssertTrue(fixture.access.secrets.removedKeys.isEmpty)
        }
    }

    func testFailedSessionWritesPropagateForBothLoginPaths() async throws {
        for helper in [false, true] {
            let fixture = try AccountOperationsFixture()
            fixture.access.secrets.failure = .write
            do {
                if helper { try await fixture.operations.connectCodexHelper() }
                else { try await fixture.operations.connectAccount(.openAI) }
                XCTFail("Expected persistence failure")
            } catch { XCTAssertEqual(error as? SettingsMemorySecretStore.Failure, .write) }
            XCTAssertTrue(fixture.access.secrets.values.isEmpty)
        }
    }

    func testFailedRemovalPropagatesEvenAfterRemoteFailure() async throws {
        for helper in [false, true] {
            let fixture = try AccountOperationsFixture()
            let original = helper ? fixture.login.helperSession.canonicalized : fixture.login.accountSession(.openAI)
            try fixture.access.manager.saveAccountSession(original)
            fixture.login.failLogout = true
            fixture.access.secrets.failure = .remove
            do {
                if helper { try await fixture.operations.disconnectCodexHelper() }
                else { try await fixture.operations.disconnectAccount(.openAI) }
                XCTFail("Expected removal failure")
            } catch { XCTAssertEqual(error as? SettingsMemorySecretStore.Failure, .remove) }
            XCTAssertEqual(fixture.access.manager.session(for: .openAI), original)
        }
    }

    func testHelperDisconnectDoesNotRemoveOrdinarySession() async throws {
        let fixture = try AccountOperationsFixture()
        let session = fixture.login.accountSession(.openAI)
        try fixture.access.manager.saveAccountSession(session)
        try await fixture.operations.disconnectCodexHelper()
        XCTAssertEqual(fixture.access.manager.session(for: .openAI), session)
        XCTAssertTrue(fixture.access.secrets.removedKeys.isEmpty)
    }

    func testLoginFailureDoesNotReplaceExistingSession() async throws {
        let fixture = try AccountOperationsFixture()
        let session = fixture.login.accountSession(.openAI)
        try fixture.access.manager.saveAccountSession(session)
        fixture.login.failLogin = true
        do { try await fixture.operations.connectAccount(.openAI); XCTFail("Expected login failure") } catch {}
        do { try await fixture.operations.connectCodexHelper(); XCTFail("Expected login failure") } catch {}
        XCTAssertEqual(fixture.access.manager.session(for: .openAI), session)
    }
}

@MainActor
private final class AccountOperationsFixture {
    let access: AccessPromptFixture
    let login = MemoryAccountLoginService()
    private(set) var resolutions = 0
    lazy var operations = ProviderAccountAccessOperations(providerAccessManager: access.manager,
        loginServiceProvider: { [unowned self] in self.resolutions += 1; return self.login })
    init() throws { access = try AccessPromptFixture(); _ = operations }
}

@MainActor
private final class AccountLogoutGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class MemoryAccountLoginService: AccountLoginService {
    var calls: [String] = []
    var failLogout = false
    var failLogin = false
    var logoutHook: (() async -> Void)?
    let helperSession = AccountSession(provider: .openAI, accountIdentifier: "helper-fixture",
        accessToken: "uncanonicalized-helper-fixture", refreshToken: "fixture-refresh",
        idToken: "fixture-id", tokenType: "fixture-type", expiresAt: Date(timeIntervalSince1970: 1),
        accessibleModelIDs: ["gpt-5-codex"])
    func accountSession(_ provider: AccountLoginProvider) -> AccountSession {
        AccountSession(provider: provider, accountIdentifier: "fixture", accessToken: "fixture-token")
    }
    func beginLogin(for provider: AccountLoginProvider) async throws -> AccountSession {
        calls.append("login:\(provider.rawValue)")
        if failLogin { throw AccessPromptFixture.Failure.operation }
        return accountSession(provider)
    }
    func beginCodexHelperLogin() async throws -> AccountSession {
        calls.append("helper-login")
        if failLogin { throw AccessPromptFixture.Failure.operation }
        return helperSession
    }
    func logout(provider: AccountLoginProvider) async throws {
        calls.append("logout:\(provider.rawValue)")
        await logoutHook?()
        if failLogout { throw AccessPromptFixture.Failure.operation }
    }
    func logoutCodexHelper() async throws {
        calls.append("helper-logout")
        await logoutHook?()
        if failLogout { throw AccessPromptFixture.Failure.operation }
    }
    func handleRedirect(_ url: URL) async throws -> AccountSession { throw AccessPromptFixture.Failure.operation }
    func refreshSession(_ session: AccountSession) async throws -> AccountSession { throw AccessPromptFixture.Failure.operation }
    func fetchAccessibleModels(for provider: AccountLoginProvider) async throws -> [String] { throw AccessPromptFixture.Failure.operation }
}
