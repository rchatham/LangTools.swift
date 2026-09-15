import Foundation
import XCTest
@testable import Chat

final class AccountBackendConfigurationTests: XCTestCase {
    func testCodexHelperRequiresHTTPExplicitPortAndLoopbackHost() throws {
        for url in [
            "https://127.0.0.1:8765",
            "http://127.0.0.1",
            "http://example.com:8765",
            "http://127.0.0.2:8765",
        ] {
            let configuration = AccountBackendConfiguration(
                codexHelperBaseURL: try XCTUnwrap(URL(string: url)),
                codexHelperToken: "helper-token"
            )
            XCTAssertThrowsError(try configuration.codexHelperRoute(), url)
        }

        for host in ["127.0.0.1", "[::1]"] {
            let configuration = AccountBackendConfiguration(
                codexHelperBaseURL: try XCTUnwrap(URL(string: "http://\(host):8765")),
                codexHelperToken: "helper-token"
            )
            XCTAssertEqual(try configuration.codexHelperRoute().destination, .codexHelper)
        }

        // `localhost` is a DNS name, not a verified loopback address, so it
        // must be rejected in favor of numeric loopback literals.
        let localhostConfiguration = AccountBackendConfiguration(
            codexHelperBaseURL: try XCTUnwrap(URL(string: "http://localhost:8765")),
            codexHelperToken: "helper-token"
        )
        XCTAssertThrowsError(try localhostConfiguration.codexHelperRoute())
    }

    func testDestinationsRejectUserInfoQueryAndFragment() throws {
        for url in [
            "http://user@127.0.0.1:8765",
            "http://127.0.0.1:8765?token=value",
            "http://127.0.0.1:8765#fragment",
        ] {
            let configuration = AccountBackendConfiguration(
                codexHelperBaseURL: try XCTUnwrap(URL(string: url)),
                codexHelperToken: "helper-token"
            )
            XCTAssertThrowsError(try configuration.codexHelperRoute(), url)
        }

        for url in [
            "https://user@example.com",
            "https://example.com?token=value",
            "https://example.com#fragment",
        ] {
            let configuration = AccountBackendConfiguration(baseURL: try XCTUnwrap(URL(string: url)))
            XCTAssertThrowsError(try configuration.claudeCodeRoute(accessToken: "account-token"), url)
        }
    }

    func testClaudeBackendRequiresHTTPSExceptForLoopbackHTTP() throws {
        XCTAssertNoThrow(try AccountBackendConfiguration(
            baseURL: URL(string: "https://accounts.example.com")!
        ).claudeCodeRoute(accessToken: "account-token"))
        XCTAssertNoThrow(try AccountBackendConfiguration(
            baseURL: URL(string: "http://127.0.0.1:8080")!
        ).claudeCodeRoute(accessToken: "account-token"))
        // `localhost` is not a verified loopback address for the Claude Code
        // backend either.
        XCTAssertThrowsError(try AccountBackendConfiguration(
            baseURL: URL(string: "http://localhost:8080")!
        ).claudeCodeRoute(accessToken: "account-token"))
        XCTAssertThrowsError(try AccountBackendConfiguration(
            baseURL: URL(string: "http://accounts.example.com")!
        ).claudeCodeRoute(accessToken: "account-token"))
    }

    func testRoutesBindDestinationToExpectedCredential() throws {
        let configuration = AccountBackendConfiguration(
            baseURL: URL(string: "https://accounts.example.com")!,
            codexHelperBaseURL: URL(string: "http://127.0.0.1:8765")!,
            codexHelperToken: "helper-token"
        )
        let codex = AccountSession(provider: .openAI, accountIdentifier: "acct", accessToken: CodexSessionMarker.value)
        let claude = AccountSession(provider: .claudeCode, accountIdentifier: "acct", accessToken: "account-token")

        XCTAssertEqual(try configuration.route(for: .openAI, session: codex).credential, .codexHelperToken("helper-token"))
        XCTAssertEqual(try configuration.route(for: .claudeCode, session: claude).credential, .accountAccessToken("account-token"))
        XCTAssertThrowsError(try configuration.route(for: .openAI, session: claude))
        XCTAssertThrowsError(try configuration.route(
            for: .openAI,
            session: AccountSession(provider: .openAI, accountIdentifier: "acct", accessToken: "raw-token")
        ))
    }
}
