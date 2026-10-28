//
//  ModelTests.swift
//  AnthropicTests
//
//  Exercises the flexible `Anthropic.Model` value type: known models via
//  `rawValue`, arbitrary/future model IDs via `customModelID`, and the
//  single-string Codable contract that keeps future IDs representable
//  without a library release.
//

import XCTest
import Anthropic

final class ModelTests: XCTestCase {

    func testCustomModelIDAcceptsFutureModelID() {
        let model = Anthropic.Model(customModelID: "claude-future-1")
        XCTAssertEqual(model.id, "claude-future-1")
        XCTAssertEqual(model.rawValue, "claude-future-1")
    }

    func testRawValueInitReturnsNilForUnknownModel() {
        XCTAssertNil(Anthropic.Model(rawValue: "claude-future-1"))
    }

    func testRawValueInitResolvesKnownModel() {
        XCTAssertEqual(Anthropic.Model(rawValue: "claude-sonnet-4-6"), .claude46Sonnet)
        XCTAssertEqual(Anthropic.Model(rawValue: "claude-haiku-4-5-20251001"), .claude45Haiku_20251001)
        XCTAssertEqual(Anthropic.Model(rawValue: "claude-opus-4-6"), .claude46Opus)
    }

    func testKnownStaticMembersPreserveModelIDs() {
        XCTAssertEqual(Anthropic.Model.claude46Opus.rawValue, "claude-opus-4-6")
        XCTAssertEqual(Anthropic.Model.claude46Sonnet.rawValue, "claude-sonnet-4-6")
        XCTAssertEqual(Anthropic.Model.claude45Haiku_latest.rawValue, "claude-haiku-4-5-latest")
        XCTAssertEqual(Anthropic.Model.claude41Opus_latest.rawValue, "claude-opus-4-1-latest")
    }

    func testCodableEncodesAsSingleString() throws {
        let data = try JSONEncoder().encode(Anthropic.Model.claude46Sonnet)
        XCTAssertEqual(String(data: data, encoding: .utf8), #""claude-sonnet-4-6""#)
    }

    func testCodableDecodesUnknownModelIDForForwardCompatibility() throws {
        let data = Data(#""claude-future-1""#.utf8)
        let model = try JSONDecoder().decode(Anthropic.Model.self, from: data)
        XCTAssertEqual(model.rawValue, "claude-future-1")
        XCTAssertEqual(model.id, "claude-future-1")
    }

    func testCodableRoundTripsKnownAndCustomModels() throws {
        for raw in ["claude-sonnet-4-6", "claude-future-1", "claude-opus-4-6-20260205"] {
            let model = Anthropic.Model(customModelID: raw)
            let data = try JSONEncoder().encode(model)
            let decoded = try JSONDecoder().decode(Anthropic.Model.self, from: data)
            XCTAssertEqual(decoded, model)
        }
    }

    func testEqualityAcrossConstructionPaths() {
        let known = Anthropic.Model.claude46Sonnet
        let fromRaw = Anthropic.Model(rawValue: "claude-sonnet-4-6")
        let custom = Anthropic.Model(customModelID: "claude-sonnet-4-6")
        XCTAssertEqual(known, fromRaw)
        XCTAssertEqual(known, custom)
    }

    func testHashingDeduplicatesAcrossConstructionPaths() {
        let set = Set([
            Anthropic.Model.claude46Sonnet,
            Anthropic.Model(customModelID: "claude-sonnet-4-6"),
            Anthropic.Model(rawValue: "claude-sonnet-4-6")!,
        ])
        XCTAssertEqual(set.count, 1)
    }

    func testCustomModelIsNotClassifiedAsKnown() {
        let future = Anthropic.Model(customModelID: "claude-future-1")
        XCTAssertFalse(Anthropic.Model.activeCases.contains(future))
        XCTAssertFalse(future.isDeprecated)
        XCTAssertFalse(future.isRetired)
        XCTAssertFalse(future.supportsStructuredOutput)
    }

    func testLifecycleClassification() {
        XCTAssertTrue(Anthropic.Model.activeCases.contains(.claude46Sonnet))
        XCTAssertTrue(Anthropic.Model.claude46Sonnet.supportsStructuredOutput)

        // Deprecated/retired members are accessed via their raw IDs to avoid
        // triggering @available(deprecated) warnings in this test.
        let deprecated = Anthropic.Model(rawValue: "claude-3-haiku-20240307")!
        let retired = Anthropic.Model(rawValue: "claude-3-7-sonnet-20250219")!
        XCTAssertTrue(deprecated.isDeprecated)
        XCTAssertFalse(deprecated.isRetired)
        XCTAssertTrue(retired.isRetired)
        XCTAssertFalse(retired.isDeprecated)
    }

    func testAllCasesIncludeActiveDeprecatedAndRetiredButNotUnknown() {
        let all = Set(Anthropic.Model.allCases)
        XCTAssertTrue(all.contains(.claude46Sonnet))
        XCTAssertTrue(all.contains(Anthropic.Model(rawValue: "claude-3-haiku-20240307")!))
        XCTAssertTrue(all.contains(Anthropic.Model(rawValue: "claude-3-sonnet-20240229")!))
        // Unknown/future IDs are representable but not enumerated as known models.
        XCTAssertFalse(all.contains(Anthropic.Model(customModelID: "claude-future-1")))
    }
}
