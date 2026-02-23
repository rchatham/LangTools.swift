//
//  GeminiTests.swift
//  GeminiTests
//
//  Created by Reid Chatham on 12/6/23.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TestUtils
@testable import Gemini
@testable import OpenAI

class GeminiTests: XCTestCase {

    var api: Gemini!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = Gemini(apiKey: "").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    func testGeminiModelRawValues() throws {
        // Verify active model IDs are correct
        XCTAssertEqual(GeminiModel.gemini3Pro.rawValue, "gemini-3-pro")
        XCTAssertEqual(GeminiModel.gemini3Flash.rawValue, "gemini-3-flash")
        XCTAssertEqual(GeminiModel.gemini31Pro.rawValue, "gemini-3.1-pro")

        // Verify deprecated model IDs
        XCTAssertEqual(GeminiModel.gemini25Flash.rawValue, "gemini-2.5-flash")
        XCTAssertEqual(GeminiModel.gemini2Flash.rawValue, "gemini-2.0-flash")

        // Verify retired model IDs
        XCTAssertEqual(GeminiModel.gemini15Flash.rawValue, "gemini-1.5-flash")
        XCTAssertEqual(GeminiModel.gemini10Pro.rawValue, "gemini-1.0-pro")
    }

    func testGeminiIsDeprecatedProperty() throws {
        // Deprecated models should return true
        XCTAssertTrue(GeminiModel.gemini25Flash.isDeprecated)
        XCTAssertTrue(GeminiModel.gemini25FlashLite.isDeprecated)
        XCTAssertTrue(GeminiModel.gemini25Pro.isDeprecated)
        XCTAssertTrue(GeminiModel.gemini2Flash.isDeprecated)
        XCTAssertTrue(GeminiModel.gemini2FlashLite.isDeprecated)

        // Active models should return false
        XCTAssertFalse(GeminiModel.gemini3Pro.isDeprecated)
        XCTAssertFalse(GeminiModel.gemini3Flash.isDeprecated)
        XCTAssertFalse(GeminiModel.gemini31Pro.isDeprecated)

        // Retired models are not "deprecated"
        XCTAssertFalse(GeminiModel.gemini15Flash.isDeprecated)
        XCTAssertFalse(GeminiModel.gemini10Pro.isDeprecated)
    }

    func testGeminiIsRetiredProperty() throws {
        // Retired models should return true
        XCTAssertTrue(GeminiModel.gemini15Flash.isRetired)
        XCTAssertTrue(GeminiModel.gemini15Flash8B.isRetired)
        XCTAssertTrue(GeminiModel.gemini15Pro.isRetired)
        XCTAssertTrue(GeminiModel.gemini10Pro.isRetired)

        // Active models should return false
        XCTAssertFalse(GeminiModel.gemini3Pro.isRetired)
        XCTAssertFalse(GeminiModel.gemini3Flash.isRetired)

        // Deprecated (but not yet retired) models should return false
        XCTAssertFalse(GeminiModel.gemini25Flash.isRetired)
        XCTAssertFalse(GeminiModel.gemini2Flash.isRetired)
    }
}

extension Gemini {
    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        openAI.configure(testURLSessionConfiguration: testURLSessionConfiguration)
        return self
    }
}
