//
//  GeminiTests.swift
//  GeminiTests
//
//  Created by Reid Chatham on 12/6/23.
//

import XCTest
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
}

extension Gemini {
    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        openAI.configure(testURLSessionConfiguration: testURLSessionConfiguration)
        return self
    }
}
