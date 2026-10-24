//
//  Utilities.swift
//  LangTools
//
//  Created by Reid Chatham on 1/1/24.
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LangTools

extension LangToolsStreamableResponse where Self: Encodable {
    func streamData() throws -> Data {
        let jsonString = try data().string
        return ("data: " + jsonString).data(using: .utf8)!
    }
}

extension XCTestCase {
    func getData(filename: String, fileExtension: String = "json") throws -> Data? {
        return try Data.getData(filename: filename, bundle: Bundle.module, fileExtension: fileExtension)
    }
}

extension Data {
    var string: String {
        return String(data: self, encoding: .utf8)!
    }
    var dictionary: [String: String]? {
        return (try? JSONSerialization.jsonObject(with: self, options: .allowFragments)).flatMap { $0 as? [String: String] }
    }
    static func getData(filename: String, bundle: Bundle, fileExtension: String = "json") throws -> Data? {
        if let path = bundle.url(forResource: filename, withExtension: fileExtension) {
            return try Data(contentsOf: path)
        }
        return nil
    }
    init(_ encodable: Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self = try encoder.encode(encodable)
    }
}

extension Encodable {
    func data(outputFormatting: JSONEncoder.OutputFormatting = [] /*[.prettyPrinted, .sortedKeys]*/) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting
        return try encoder.encode(self)
    }
}

/// A test case whose `session` routes through `MockURLProtocol`; handlers are reset after each test.
open class MockSessionTestCase: XCTestCase {
    public var session: URLSession!

    open override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    open override func tearDown() {
        MockURLProtocol.resetHandlers()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    /// The JSON object body of a prepared request.
    public func body(of urlRequest: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.bodyData ?? urlRequest.httpBody)) as? [String: Any])
    }
}
