import Foundation
import XCTest

final class PerformanceRatiosConfigurationTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("ratios.json")
    }

    func testMissingFileFailsClosed() throws {
        let url = try temporaryURL()
        XCTAssertThrowsError(try PerformanceRatios.load(from: url))
        XCTAssertThrowsError(try PerformanceRatios.ceiling(for: "missing", from: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMissingKeyFailsClosed() throws {
        let url = try temporaryURL()
        try Data(#"{"existing":0.5}"#.utf8).write(to: url)
        XCTAssertThrowsError(try PerformanceRatios.ceiling(for: "missing", from: url)) {
            XCTAssertEqual($0 as? PerformanceRatios.ConfigurationError, .missingKey("missing"))
        }
        XCTAssertEqual(try PerformanceRatios.ceiling(for: "existing", from: url), 0.5)
    }

    func testMalformedAndInvalidConfigurationCannotBeLoadedOrRecordedOver() throws {
        let url = try temporaryURL()
        for json in ["{", "[]", #"{"key":"bad"}"#, #"{"key":null}"#, #"{"key":0}"#, #"{"key":-1}"#, #"{"key":1e999}"#] {
            let original = Data(json.utf8)
            try original.write(to: url)
            XCTAssertThrowsError(try PerformanceRatios.load(from: url), json)
            XCTAssertThrowsError(try PerformanceRatios.record(key: "new", observedRatio: 1, to: url), json)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testRecordBootstrapsMissingFileAndKeyAndPreservesOtherCeilings() throws {
        let url = try temporaryURL()
        try PerformanceRatios.record(key: "first", observedRatio: 1, to: url)
        XCTAssertEqual(try PerformanceRatios.load(from: url), ["first": 1.4])
        try PerformanceRatios.record(key: "second", observedRatio: 2, to: url)
        XCTAssertEqual(try PerformanceRatios.load(from: url), ["first": 1.4, "second": 2.8])
        try PerformanceRatios.record(key: "second", observedRatio: 3, to: url)
        XCTAssertEqual(try PerformanceRatios.load(from: url), ["first": 1.4, "second": 4.2])
    }

    func testRecordRejectsInvalidObservationsWithoutWriting() throws {
        let url = try temporaryURL()
        for ratio in [0, -1, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try PerformanceRatios.record(key: "key", observedRatio: ratio, to: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testReadFailurePropagatesInNormalAndRecordModes() throws {
        // A directory at the file path is deterministic even when running as root.
        let url = try temporaryURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try PerformanceRatios.load(from: url))
        XCTAssertThrowsError(try PerformanceRatios.record(key: "key", observedRatio: 1, to: url))
    }

    func testRecordWriteFailurePropagates() throws {
        // Bootstrap cannot atomically write beneath a nonexistent parent directory.
        let url = try temporaryURL().appendingPathComponent("missing/ratios.json")
        XCTAssertThrowsError(try PerformanceRatios.record(key: "key", observedRatio: 1, to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
