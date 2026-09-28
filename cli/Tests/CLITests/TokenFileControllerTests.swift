#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import HelperCore
@testable import LangToolsHelper

final class TokenFileControllerTests: XCTestCase {
    func testGenerates64HexTokenWithOwnerOnlyPermissionsAndNoTrailingNewline() throws {
        let tokenURL = try makeTokenURL()
        let controller = TokenFileController(tokenFileURL: tokenURL)

        let token = try controller.ensureToken()

        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy { $0.isASCII && $0.isHexDigit })
        XCTAssertEqual(token, token.lowercased())
        let data = try Data(contentsOf: tokenURL)
        XCTAssertEqual(String(data: data, encoding: .utf8), token)
        XCTAssertNotEqual(data.last, UInt8(ascii: "\n"))
        let attributes = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0, 0o600)
        // The generated file must satisfy the loader's secure-file rules.
        XCTAssertEqual(try HelperTokenLoader.load(from: tokenURL.path), token)
    }

    func testRotatesLegacyNonHexTokenFile() throws {
        let tokenURL = try makeTokenURL()
        try Data("0123456789abcdef".utf8).write(to: tokenURL)
        XCTAssertEqual(chmod(tokenURL.path, 0o600), 0)
        let controller = TokenFileController(tokenFileURL: tokenURL)

        let token = try controller.ensureToken()

        // A loader-valid but pairing-incompatible token is rotated to 64 hex.
        XCTAssertNotEqual(token, "0123456789abcdef")
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy { $0.isASCII && $0.isHexDigit })
        XCTAssertEqual(String(data: try Data(contentsOf: tokenURL), encoding: .utf8), token)
    }

    func testReusesValid64HexExistingTokenFile() throws {
        let tokenURL = try makeTokenURL()
        let existing = String(repeating: "ab", count: 32)
        try Data(existing.utf8).write(to: tokenURL)
        XCTAssertEqual(chmod(tokenURL.path, 0o600), 0)
        let controller = TokenFileController(tokenFileURL: tokenURL)

        let token = try controller.ensureToken()

        XCTAssertEqual(token, existing)
        XCTAssertEqual(String(data: try Data(contentsOf: tokenURL), encoding: .utf8), existing)
    }

    func testSurfacesErrorForInsecureExistingTokenFile() throws {
        let tokenURL = try makeTokenURL()
        try Data("insecure-token".utf8).write(to: tokenURL)
        XCTAssertEqual(chmod(tokenURL.path, 0o644), 0)
        let controller = TokenFileController(tokenFileURL: tokenURL)

        XCTAssertThrowsError(try controller.ensureToken()) { error in
            XCTAssertTrue(error is HelperTokenFileError, "expected a HelperTokenFileError, got \(error)")
        }
    }

    private func makeTokenURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-helper-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("helper-token")
    }
}