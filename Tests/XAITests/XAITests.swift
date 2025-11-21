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
}

extension XAI {
    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        openAI.configure(testURLSessionConfiguration: testURLSessionConfiguration)
        return self
    }
}
