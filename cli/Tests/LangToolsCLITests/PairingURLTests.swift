import Foundation
import XCTest
@testable import LangToolsHelper

final class PairingURLTests: XCTestCase {
    func testBuildsExactPairingContractURL() throws {
        let token = String(repeating: "ab", count: 32)
        let url = try PairingURL.make(port: 8765, token: token)

        XCTAssertEqual(url.scheme, "langtools-example-auth")
        XCTAssertEqual(url.host, "codex-helper")
        XCTAssertEqual(url.path, "/pair")
        XCTAssertEqual(
            url.absoluteString,
            "langtools-example-auth://codex-helper/pair?port=8765&token=\(token)"
        )
    }

    func testRejectsInvalidPortsAndTokenShapes() {
        let token = String(repeating: "cd", count: 32)
        XCTAssertThrowsError(try PairingURL.make(port: 0, token: token))
        XCTAssertThrowsError(try PairingURL.make(port: 8765, token: "short"))
        XCTAssertThrowsError(try PairingURL.make(port: 8765, token: token + "zz"))
        XCTAssertThrowsError(try PairingURL.make(port: 8765, token: String(repeating: "g", count: 64)))
        XCTAssertThrowsError(try PairingURL.make(port: 8765, token: String(repeating: "ab1", count: 22)))
    }
}