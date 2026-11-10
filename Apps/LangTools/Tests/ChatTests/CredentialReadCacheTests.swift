import XCTest
@testable import Chat

final class CredentialReadCacheTests: XCTestCase {
    func testReadsMissingValuesAndFailuresOnlyOnceUntilInvalidated() throws {
        let cache = CredentialReadCache<String>()
        var reads = 0
        for _ in 0..<10 {
            XCTAssertNil(try cache.read("missing") { reads += 1; return nil })
        }
        XCTAssertEqual(reads, 1)
        enum Denied: Error { case access }
        for _ in 0..<10 {
            XCTAssertThrowsError(try cache.read("denied") { reads += 1; throw Denied.access })
        }
        XCTAssertEqual(reads, 2)
        cache.invalidate()
        XCTAssertEqual(try cache.read("denied") { "retry" }, "retry")
    }

    func testWritesAndDeletesUpdateCacheOnlyAfterPersistence() throws {
        let cache = CredentialReadCache<String>()
        _ = try cache.read("key") { "old" }
        enum Failed: Error { case write }
        XCTAssertThrowsError(try cache.write("key", value: "new") { throw Failed.write })
        XCTAssertEqual(try cache.read("key") { XCTFail(); return nil }, "old")
        try cache.write("key", value: "new") {}
        XCTAssertEqual(try cache.read("key") { XCTFail(); return nil }, "new")
        try cache.write("key", value: nil) {}
        XCTAssertNil(try cache.read("key") { XCTFail(); return "unexpected" })
    }
}
