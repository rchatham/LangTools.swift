import Foundation
import XCTest
@testable import Chat

final class CodexHelperPairingTests: XCTestCase {
    /// 64 hex characters.
    private static let validCode = String(repeating: "ab", count: 32)

    // MARK: - Valid pairing URLs

    func testValidPairingURLExtractsPortAndToken() throws {
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

    func testUppercaseHexTokenIsAccepted() throws {
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

    func testRejectsMissingTokenQueryItem() {
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

    func testRejectsNonHexToken() {
        let nonHexCode = String(repeating: "gg", count: 32)
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=8765&code=\(nonHexCode)",
            expected: .invalidCode
        )
    }

    func testRejectsSixtyThreeCharacterToken() {
        let shortCode = String(repeating: "ab", count: 31) + "a"
        assertParseFailure(
            "langtools-example-auth://codex-helper/pair?port=8765&code=\(shortCode)",
            expected: .invalidCode
        )
    }

    func testRejectsSixtyFiveCharacterToken() {
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