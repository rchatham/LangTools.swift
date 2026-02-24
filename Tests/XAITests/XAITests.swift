//
//  XAITests.swift
//  XAITests
//
//  Created by Reid Chatham on 12/6/23.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TestUtils
@testable import XAI
@testable import OpenAI

class XAITests: XCTestCase {

    var api: XAI!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = XAI(apiKey: "").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    func testXAIModelRawValues() throws {
        // Verify active model IDs are correct
        XCTAssertEqual(XAIModel.grok3.rawValue, "grok-3")
        XCTAssertEqual(XAIModel.grok4_0709.rawValue, "grok-4-0709")
        XCTAssertEqual(XAIModel.grok2Vision.rawValue, "grok-2-vision-1212")
        XCTAssertEqual(XAIModel.grokCodeFast.rawValue, "grok-code-fast-1")

        // Verify deprecated model IDs
        XCTAssertEqual(XAIModel.grokBeta.rawValue, "grok-beta")
        XCTAssertEqual(XAIModel.grok.rawValue, "grok-2-1212")
    }

    func testGrokVisionBackwardCompatAlias() throws {
        // grokVision is a deprecated alias for grok2Vision; both resolve to the same raw value
        XCTAssertEqual(XAIModel.grokVision.rawValue, XAIModel.grok2Vision.rawValue)
        XCTAssertEqual(XAIModel.grokVision.rawValue, "grok-2-vision-1212")
    }

    func testXAIIsDeprecatedProperty() throws {
        // Deprecated models should return true
        XCTAssertTrue(XAIModel.grokBeta.isDeprecated)
        XCTAssertTrue(XAIModel.grok.isDeprecated)

        // Active models should return false
        XCTAssertFalse(XAIModel.grok3.isDeprecated)
        XCTAssertFalse(XAIModel.grok3_mini.isDeprecated)
        XCTAssertFalse(XAIModel.grok4_0709.isDeprecated)
        XCTAssertFalse(XAIModel.grok2Vision.isDeprecated)
    }
}

extension XAI {
    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        openAI.configure(testURLSessionConfiguration: testURLSessionConfiguration)
        return self
    }
}
