import Foundation
import XCTest
@testable import Chat

final class CodexHelperPairingTests: XCTestCase {
    /// 64 hex characters.
    private static let validCode = String(repeating: "ab", count: 32)

    // MARK: - Valid pairing URLs

    func testValidPairingURLExtractsPortAndCode() throws {
        let url = pairingURL(port: "8765", code: Self.validCode)

        let helper = try CodexHelperPairingCoordinator.parsePairingURL(url).get()

        XCTAssertEqual(helper.port, 8765)
        XCTAssertEqual(helper.code, Self.validCode)
    }

    func testSchemeMatchingIsCaseInsensitive() throws {
        let url = URL(string: "LANGTOOLS-EXAMPLE-AUTH://codex-helper/pair?port=8765&code=\(Self.validCode)")!

        let helper = try CodexHelperPairingCoordinator.parsePairingURL(url).get()

        XCTAssertEqual(helper.port, 8765)
        XCTAssertEqual(helper.code, Self.validCode)
    }

    func testHostMatchingIsCaseInsensitive() throws {
        let url = URL(string: "langtools-example-auth://CODEX-HELPER/pair?port=8765&code=\(Self.validCode)")!

        let helper = try CodexHelperPairingCoordinator.parsePairingURL(url).get()

        XCTAssertEqual(helper.port, 8765)
        XCTAssertEqual(helper.code, Self.validCode)
    }

    func testUppercaseHexCodeIsAccepted() throws {
        let uppercaseCode = String(repeating: "AB", count: 32)
        let url = pairingURL(port: "8765", code: uppercaseCode)

        let helper = try CodexHelperPairingCoordinator.parsePairingURL(url).get()

        XCTAssertEqual(helper.port, 8765)
        XCTAssertEqual(helper.code, uppercaseCode)
    }

    // MARK: - Rejected pairing URLs

    func testRejectsUnexpectedScheme() {
        assertParseFailure(
            "https://codex-helper/pair?port=8765&code=\(Self.validCode)",
            expected: .invalidScheme
        )
    }

    func testRejectsWrongHost() {
        assertParseFailure(
            "langtools-example-auth://evil-helper/pair?port=8765&code=\(Self.validCode)",
            expected: .invalidHost
        )
    }

    func testRejectsWrongPath() {
        assertParseFailure(
            "langtools-example-auth://codex-helper/pairing?port=8765&code=\(Self.validCode)",
            expected: .invalidPath
        )
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair/?port=8765&code=\(Self.validCode)",
            expected: .invalidPath
        )
        assertParseFailure(
            "langtools-example-auth://codex-helper?port=8765&code=\(Self.validCode)",
            expected: .invalidPath
        )
    }

    func testRejectsPortZero() {
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=0&code=\(Self.validCode)",
            expected: .invalidPort
        )
    }

    func testRejectsPortAboveValidRange() {
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=65536&code=\(Self.validCode)",
            expected: .invalidPort
        )
    }

    func testRejectsNonNumericPort() {
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=87a5&code=\(Self.validCode)",
            expected: .invalidPort
        )
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=8765%20&code=\(Self.validCode)",
            expected: .invalidPort
        )
    }

    func testRejectsMissingPortQueryItem() {
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?code=\(Self.validCode)",
            expected: .invalidPort
        )
    }

    func testRejectsMissingCodeQueryItem() {
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=8765",
            expected: .invalidCode
        )
    }

    func testRejectsURLWithoutQuery() {
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair",
            expected: .invalidPort
        )
    }

    func testRejectsNonHexCode() {
        let nonHexCode = String(repeating: "gg", count: 32)
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=8765&code=\(nonHexCode)",
            expected: .invalidCode
        )
    }

    func testRejectsSixtyThreeCharacterCode() {
        let shortCode = String(repeating: "ab", count: 31) + "a"
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=8765&code=\(shortCode)",
            expected: .invalidCode
        )
    }

    func testRejectsSixtyFiveCharacterCode() {
        let longCode = String(repeating: "ab", count: 32) + "c"
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=8765&code=\(longCode)",
            expected: .invalidCode
        )
    }

    func testRejectsDuplicateOrExtraParameters() {
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=8765&code=\(Self.validCode)&code=\(Self.validCode)",
            expected: .malformedURL
        )
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=8765&code=\(Self.validCode)&extra=1",
            expected: .malformedURL
        )
    }

    func testRejectsURLCredentialsAndFragments() {
        assertParseFailure(
            "langtools-example-auth://user@codex-helper/pair?port=8765&code=\(Self.validCode)",
            expected: .invalidPath
        )
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=8765&code=\(Self.validCode)#fragment",
            expected: .invalidPath
        )
    }

    // MARK: - Coordinator

    @MainActor
    func testHandleStoresValidPairingAsPending() {
        let coordinator = makeCoordinator()

        coordinator.handle(pairingURL(port: "8765", code: Self.validCode))

        XCTAssertEqual(coordinator.pendingPairing, PairedHelper(port: 8765, code: Self.validCode))
    }

    @MainActor
    func testHandleIgnoresInvalidPairingURLs() {
        let coordinator = makeCoordinator()

        coordinator.handle(pairingURL(port: "0", code: Self.validCode))
        coordinator.handle(pairingURL(port: "8765", code: "not-hex"))
        coordinator.handle(pairingURL(port: "8765", code: String(repeating: "ab", count: 31)))

        XCTAssertNil(coordinator.pendingPairing)
    }

    @MainActor
    func testHandleIgnoresNonPairingURLs() {
        let coordinator = makeCoordinator()
        let accountCallback = URL(string: "langtools-example-auth://auth/callback/openAI?code=abc")!

        coordinator.handle(accountCallback)
        coordinator.handle(URL(string: "https://example.com/pair?port=8765&code=\(Self.validCode)")!)

        XCTAssertNil(coordinator.pendingPairing)
    }

    @MainActor
    func testCancelClearsPendingPairing() {
        let coordinator = makeCoordinator()
        coordinator.handle(pairingURL(port: "8765", code: Self.validCode))
        XCTAssertNotNil(coordinator.pendingPairing)

        coordinator.cancel()

        XCTAssertNil(coordinator.pendingPairing)
    }

    @MainActor
    func testStorageFailureDoesNotChangeEndpoint() async throws {
        struct StorageFailure: LocalizedError {
            var errorDescription: String? { "Keychain unavailable" }
        }
        let oldURL = UserDefaults.codexHelperBaseURL
        let coordinator = CodexHelperPairingCoordinator(
            makeHelperClient: { _ in HealthyHelperClient() },
            saveToken: { _ in throw StorageFailure() },
            exchangeCode: { _, port in PairingCodeExchangeResponse(port: port, token: Self.validCode) }
        )
        let pairing = PairedHelper(port: 8766, code: Self.validCode)
        coordinator.handle(pairingURL(port: "8766", code: Self.validCode))

        coordinator.confirm(pairing)
        for _ in 0..<50 {
            if coordinator.lastPairingResult != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(UserDefaults.codexHelperBaseURL, oldURL)
        XCTAssertNil(coordinator.pairedHelper)
        XCTAssertEqual(coordinator.lastPairingResult, .verificationFailed(port: 8766, message: "Keychain unavailable"))
    }

    @MainActor
    func testHealthFailureDoesNotPersistTokenOrEndpoint() async throws {
        let oldURL = UserDefaults.codexHelperBaseURL
        let coordinator = CodexHelperPairingCoordinator(
            makeHelperClient: { _ in UnreachableHelperClient() },
            saveToken: { _ in XCTFail("Must not save before verifying the helper") },
            exchangeCode: { _, port in PairingCodeExchangeResponse(port: port, token: Self.validCode) }
        )
        coordinator.handle(pairingURL(port: "8766", code: Self.validCode))
        coordinator.confirm(PairedHelper(port: 8766, code: Self.validCode))
        for _ in 0..<50 {
            if coordinator.lastPairingResult != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(UserDefaults.codexHelperBaseURL, oldURL)
        XCTAssertNil(coordinator.pairedHelper)
        guard case .verificationFailed = coordinator.lastPairingResult else {
            return XCTFail("Expected a failed health check")
        }
    }

    @MainActor
    func testNewLinkCannotReplaceAnExistingConfirmationPrompt() {
        let coordinator = makeCoordinator()
        coordinator.handle(pairingURL(port: "8765", code: Self.validCode))
        coordinator.handle(pairingURL(port: "8766", code: Self.validCode))

        XCTAssertEqual(coordinator.pendingPairing?.port, 8765)
    }

    @MainActor
    func testConfirmSuccessSetsVerifiedState() async throws {
        let oldURL = UserDefaults.codexHelperBaseURL
        defer { UserDefaults.codexHelperBaseURL = oldURL }
        var savedToken: String?
        let coordinator = CodexHelperPairingCoordinator(
            makeHelperClient: { _ in HealthyHelperClient() },
            saveToken: { savedToken = $0 },
            exchangeCode: { _, port in PairingCodeExchangeResponse(port: port, token: Self.validCode) }
        )
        coordinator.handle(pairingURL(port: "8766", code: Self.validCode))
        coordinator.confirm(PairedHelper(port: 8766, code: Self.validCode))
        for _ in 0..<50 {
            if coordinator.lastPairingResult != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(savedToken, Self.validCode)
        XCTAssertEqual(coordinator.pairedHelper, PairedHelper(port: 8766, code: ""))
        XCTAssertEqual(coordinator.lastPairingResult, .verified(port: 8766))
        XCTAssertEqual(UserDefaults.codexHelperBaseURL, URL(string: "http://127.0.0.1:8766"))
    }

    @MainActor
    func testExchangeFailureReportsVerificationFailed() async throws {
        struct ExchangeFailure: LocalizedError {
            var errorDescription: String? { "Invalid or expired pairing code." }
        }
        let coordinator = CodexHelperPairingCoordinator(
            makeHelperClient: { _ in HealthyHelperClient() },
            saveToken: { _ in XCTFail("Must not save after a failed exchange") },
            exchangeCode: { _, _ in throw ExchangeFailure() }
        )
        coordinator.handle(pairingURL(port: "8766", code: Self.validCode))
        coordinator.confirm(PairedHelper(port: 8766, code: Self.validCode))
        for _ in 0..<50 {
            if coordinator.lastPairingResult != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNil(coordinator.pairedHelper)
        XCTAssertEqual(coordinator.lastPairingResult, .verificationFailed(port: 8766, message: "Invalid or expired pairing code."))
    }

    @MainActor
    func testSecondConfirmSupersedesStaleExchange() async throws {
        let oldURL = UserDefaults.codexHelperBaseURL
        defer { UserDefaults.codexHelperBaseURL = oldURL }
        let enteredExchange = AsyncStream.makeStream(of: Void.self)
        let proceedWithExchange = AsyncStream.makeStream(of: Void.self)
        let gate = UnsafeCounter()
        let coordinator = CodexHelperPairingCoordinator(
            makeHelperClient: { _ in HealthyHelperClient() },
            saveToken: { _ in },
            exchangeCode: { code, port in
                let callIndex = gate.increment()
                if callIndex == 1 {
                    enteredExchange.continuation.yield(())
                    await proceedWithExchange.stream.first { _ in true }
                }
                return PairingCodeExchangeResponse(port: port, token: Self.validCode)
            }
        )
        // Start the first exchange and wait for it to enter the gated block
        coordinator.handle(pairingURL(port: "8766", code: Self.validCode))
        coordinator.confirm(PairedHelper(port: 8766, code: Self.validCode))
        _ = await enteredExchange.stream.first { _ in true }

        // Cancel (supersede) and start a fresh pairing
        coordinator.cancel()
        coordinator.handle(pairingURL(port: "8767", code: Self.validCode))
        coordinator.confirm(PairedHelper(port: 8767, code: Self.validCode))

        // Let the stale exchange complete
        proceedWithExchange.continuation.yield(())

        // Wait for the second confirm to finish
        for _ in 0..<50 {
            if let result = coordinator.lastPairingResult, result != PairingOutcome.verified(port: 8766) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // The stale first exchange must not overwrite the second confirm's result
        XCTAssertEqual(coordinator.pairedHelper, PairedHelper(port: 8767, code: ""))
        XCTAssertEqual(coordinator.lastPairingResult, PairingOutcome.verified(port: 8767))
        XCTAssertEqual(UserDefaults.codexHelperBaseURL, URL(string: "http://127.0.0.1:8767"))
    }

    @MainActor
    func testExchangePortOutOfRangeReportsVerificationFailed() async throws {
        // confirm() must reject an exchange response whose port is invalid,
        // even when the health check would otherwise succeed.
        let coordinator = CodexHelperPairingCoordinator(
            makeHelperClient: { _ in HealthyHelperClient() },
            saveToken: { _ in XCTFail("Must not save after a port-range failure") },
            exchangeCode: { _, _ in PairingCodeExchangeResponse(port: 99999, token: Self.validCode) }
        )
        coordinator.handle(pairingURL(port: "8766", code: Self.validCode))
        coordinator.confirm(PairedHelper(port: 8766, code: Self.validCode))
        for _ in 0..<50 {
            if coordinator.lastPairingResult != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(coordinator.pairedHelper)
        guard case .verificationFailed(let port, let message) = coordinator.lastPairingResult else {
            return XCTFail("Expected verificationFailed")
        }
        XCTAssertEqual(port, 8766)
        XCTAssertTrue(message.contains("invalid port"), "Expected port-range error, got: \(message)")
    }

    @MainActor
    func testExchangePortMustMatchConfirmedPort() async throws {
        let oldURL = UserDefaults.codexHelperBaseURL
        defer { UserDefaults.codexHelperBaseURL = oldURL }
        var madeHelperClient = false
        var savedToken: String?
        let coordinator = CodexHelperPairingCoordinator(
            makeHelperClient: { _ in
                madeHelperClient = true
                return HealthyHelperClient()
            },
            saveToken: { savedToken = $0 },
            exchangeCode: { _, _ in PairingCodeExchangeResponse(port: 9999, token: Self.validCode) }
        )

        coordinator.confirm(PairedHelper(port: 8766, code: Self.validCode))
        for _ in 0..<50 {
            if coordinator.lastPairingResult != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(madeHelperClient, "A mismatched response port must fail before the health check.")
        XCTAssertNil(savedToken)
        XCTAssertNil(coordinator.pairedHelper)
        XCTAssertEqual(UserDefaults.codexHelperBaseURL, oldURL)
        guard case .verificationFailed(let port, let message) = coordinator.lastPairingResult else {
            return XCTFail("Expected verificationFailed")
        }
        XCTAssertEqual(port, 8766)
        XCTAssertTrue(message.contains("does not match the confirmed port"), "Unexpected error: \(message)")
    }

    @MainActor
    func testPairingStatusDowngradesAndFallsBackToPersistedState() async throws {
        let oldURL = UserDefaults.codexHelperBaseURL
        defer { UserDefaults.codexHelperBaseURL = oldURL }
        let persistedToken = PersistedTokenBox(Self.validCode)
        let coordinator = CodexHelperPairingCoordinator(
            makeHelperClient: { _ in HealthyHelperClient() },
            saveToken: { persistedToken.value = $0 },
            exchangeCode: { _, port in PairingCodeExchangeResponse(port: port, token: Self.validCode) },
            loadPersistedToken: { persistedToken.value }
        )

        coordinator.confirm(PairedHelper(port: 8766, code: Self.validCode))
        for _ in 0..<50 {
            if coordinator.lastPairingResult != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(coordinator.pairingStatus, .verified(port: 8766))

        persistedToken.value = "manually-edited-token"
        XCTAssertEqual(coordinator.pairingStatus, .paired(port: 8766))

        coordinator.dismissResult()
        XCTAssertEqual(coordinator.pairingStatus, .paired(port: 8766))

        persistedToken.value = ""
        XCTAssertEqual(coordinator.pairingStatus, .notPaired)
    }

    // MARK: - applyHydratedHelperConfigurationIfTokenUnedited

    @MainActor
    func testTokenRefreshPreservesUserEdits() {
        let viewModel = ChatSettingsView.ViewModel(clearMessages: {})
        viewModel.codexHelperToken = "user-edited-token"
        let urlBefore = viewModel.codexHelperBaseURLString
        viewModel.lastSyncedHelperTokenSnapshot = "different-token"

        viewModel.applyHydratedHelperConfigurationIfTokenUnedited(port: 8766)

        // Must not overwrite — the token differs from the snapshot
        XCTAssertEqual(viewModel.codexHelperToken, "user-edited-token")
        XCTAssertEqual(viewModel.lastSyncedHelperTokenSnapshot, "different-token")
        XCTAssertEqual(viewModel.codexHelperBaseURLString, urlBefore)
    }

    @MainActor
    func testTokenRefreshSyncsWhenTokenMatchesSyncedSnapshot() {
        let oldToken = UserDefaults.codexHelperToken
        let oldURL = UserDefaults.codexHelperBaseURL
        defer {
            UserDefaults.codexHelperToken = oldToken
            UserDefaults.codexHelperBaseURL = oldURL
        }
        let viewModel = ChatSettingsView.ViewModel(clearMessages: {})
        UserDefaults.codexHelperToken = "fresh-token"
        UserDefaults.codexHelperBaseURL = URL(string: "http://127.0.0.1:8766")!
        viewModel.codexHelperToken = "stale-token"
        viewModel.lastSyncedHelperTokenSnapshot = "stale-token"
        viewModel.codexHelperBaseURLString = "http://127.0.0.1:9999"
        viewModel.lastSyncedHelperURLSnapshot = viewModel.codexHelperBaseURLString

        viewModel.applyHydratedHelperConfigurationIfTokenUnedited(port: 8766)

        XCTAssertEqual(viewModel.codexHelperToken, "fresh-token")
        XCTAssertEqual(viewModel.lastSyncedHelperTokenSnapshot, "fresh-token")
        XCTAssertEqual(viewModel.codexHelperBaseURLString, "http://127.0.0.1:8766")
        XCTAssertEqual(viewModel.lastSyncedHelperURLSnapshot, "http://127.0.0.1:8766")
    }

    @MainActor
    func testTokenRefreshPreservesURLBeingEdited() {
        let oldToken = UserDefaults.codexHelperToken
        defer { UserDefaults.codexHelperToken = oldToken }
        let viewModel = ChatSettingsView.ViewModel(clearMessages: {})
        let originalURL = viewModel.codexHelperBaseURLString
        UserDefaults.codexHelperToken = "newly-paired-token"
        let draftURL = originalURL + "/draft"
        viewModel.codexHelperBaseURLString = draftURL

        viewModel.applyHydratedHelperConfigurationIfTokenUnedited(port: 8766)

        XCTAssertEqual(viewModel.codexHelperToken, "newly-paired-token")
        XCTAssertEqual(viewModel.codexHelperBaseURLString, draftURL)
        XCTAssertEqual(viewModel.lastSyncedHelperURLSnapshot, originalURL)
    }

    // MARK: - Helpers

    private final class PersistedTokenBox {
        var value: String

        init(_ value: String) {
            self.value = value
        }
    }

    private final class UnsafeCounter: @unchecked Sendable {
        /// Serial-only: this counter must only be accessed from the
        /// same serial execution context as the exchange closure.
        private var _value = 0
        func increment() -> Int {
            _value += 1
            return _value
        }
    }

    // MARK: - Helpers

    @MainActor
    private func makeCoordinator() -> CodexHelperPairingCoordinator {
        CodexHelperPairingCoordinator(makeHelperClient: { _ in UnreachableHelperClient() })
    }

    private func pairingURL(port: String, code: String) -> URL {
        URL(string: "langtools-example-auth://codex-helper/pair?port=\(port)&code=\(code)")!
    }

    private func assertParseFailure(_ urlString: String, expected: PairingError, file: StaticString = #filePath, line: UInt = #line) {
        guard let url = URL(string: urlString) else {
            return XCTFail("Fixture URL could not be constructed: \(urlString)", file: file, line: line)
        }

        XCTAssertEqual(
            CodexHelperPairingCoordinator.parsePairingURL(url),
            .failure(expected),
            file: file,
            line: line
        )
    }
}

/// Test double that verifies without touching loopback or Keychain.
private struct HealthyHelperClient: CodexHelperClientProtocol {
    func loginOpenAI() async throws -> AccountSession { throw URLError(.cannotConnectToHost) }
    func logoutOpenAI() async throws { throw URLError(.cannotConnectToHost) }
    func statusOpenAI() async throws -> CodexHelperStatus { throw URLError(.cannotConnectToHost) }
    func listOpenAIModels() async throws -> [String] { throw URLError(.cannotConnectToHost) }
    func healthCheck() async throws -> HelperHealthStatus { HelperHealthStatus(status: "ok", version: 1) }
}

/// Test double that guarantees coordinator tests never perform network I/O.
private struct UnreachableHelperClient: CodexHelperClientProtocol {
    private func fail() -> Error { URLError(.cannotConnectToHost) }

    func loginOpenAI() async throws -> AccountSession { throw fail() }
    func logoutOpenAI() async throws { throw fail() }
    func statusOpenAI() async throws -> CodexHelperStatus { throw fail() }
    func listOpenAIModels() async throws -> [String] { throw fail() }
    func healthCheck() async throws -> HelperHealthStatus { throw fail() }
}
