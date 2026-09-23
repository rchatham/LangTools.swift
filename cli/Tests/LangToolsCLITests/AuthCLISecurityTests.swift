import Foundation
import XCTest
@testable import CLI

final class AuthCLISecurityTests: XCTestCase {
    func testOAuthURLMetadataOmitsCodeStateAndQuery() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:1455/auth/callback?code=secret-code&state=secret-state"))

        let metadata = AuthDebugLogger.urlMetadata(url)

        XCTAssertEqual(metadata, "http://localhost:1455/auth/callback")
        XCTAssertFalse(metadata.contains("secret-code"))
        XCTAssertFalse(metadata.contains("secret-state"))
        XCTAssertFalse(metadata.contains("?"))
    }

    func testOptInAuthLogPersistsOnlyRedactedCallbackMetadata() throws {
        let logURL = temporaryLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let logger = AuthDebugLogger(fileURL: logURL, enabled: true)
        let callback = try XCTUnwrap(URL(string: "http://localhost:1455/auth/callback?code=secret-code&state=secret-state"))

        logger.log("callback destination=\(AuthDebugLogger.urlMetadata(callback)) query=<redacted>")
        let contents = try String(contentsOf: logURL, encoding: .utf8)

        XCTAssertTrue(contents.contains("/auth/callback"))
        XCTAssertTrue(contents.contains("query=<redacted>"))
        XCTAssertFalse(contents.contains("secret-code"))
        XCTAssertFalse(contents.contains("secret-state"))
    }

    func testAuthLoggingIsDisabledByDefault() {
        let logURL = temporaryLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let logger = AuthDebugLogger(fileURL: logURL, enabled: false)

        logger.log("must not persist")

        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    private func temporaryLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
    }
}
