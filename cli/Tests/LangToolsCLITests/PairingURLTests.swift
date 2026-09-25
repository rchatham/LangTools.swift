import Foundation
import XCTest
@testable import LangToolsHelper

final class PairingURLTests: XCTestCase {
    func testBuildsExactPairingContractURL() throws {
        let code = String(repeating: "ab", count: 32)
        let url = try PairingURL.make(port: 8765, code: code)

        XCTAssertEqual(url.scheme, "langtools-example-auth")
        XCTAssertEqual(url.host, "codex-helper")
        XCTAssertEqual(url.path, "/pair")
        XCTAssertEqual(
            url.absoluteString,
            "langtools-example-auth://codex-helper/pair?port=8765&code=\(code)"
        )
    }

    func testRejectsInvalidPortsAndCodeShapes() {
        let code = String(repeating: "cd", count: 32)
        XCTAssertThrowsError(try PairingURL.make(port: 0, code: code))
        XCTAssertThrowsError(try PairingURL.make(port: 8765, code: "short"))
        XCTAssertThrowsError(try PairingURL.make(port: 8765, code: code + "zz"))
        XCTAssertThrowsError(try PairingURL.make(port: 8765, code: String(repeating: "g", count: 64)))
        XCTAssertThrowsError(try PairingURL.make(port: 8765, code: String(repeating: "ab1", count: 22)))
    }
}