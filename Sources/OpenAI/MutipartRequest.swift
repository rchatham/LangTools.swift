//
//  MutipartRequest.swift
//  LangTools
//
//  Created by Reid Chatham on 12/21/24.
//

import Foundation


protocol MultipartFormDataEncodableRequest {
    var httpBody: Data { get }
}

// MultipartRequest
public struct MultipartRequest {
    public let boundary: String

    private let separator: String = "\r\n"
    private var data: Data

    public init(boundary: String = UUID().uuidString) {
        self.boundary = boundary
        self.data = .init()
    }

    private init(boundary: String, data: Data) {
        self.boundary = boundary
        self.data = data
    }

    public func add(key: String, value: Any?) -> Self {
        guard let value else { return self }
        var data = data
        data.append("--\(boundary)")
        data.append(separator)
        data.append(disposition(key) + separator)
        data.append(separator)
        data.append("\(value)" + separator)
        return MultipartRequest(boundary: boundary, data: data)
    }

    public func file(fileName: String, contentType: String, fileData: Data) -> Self {
        var data = data
        data.append("--\(boundary)")
        data.append(separator)
        data.append(disposition("file") + "; filename=\"\(fileName)\"" + separator)
        data.append("Content-Type: \(contentType)" + separator + separator)
        data.append(fileData)
        data.append(separator)
        return MultipartRequest(boundary: boundary, data: data)
    }

    public var httpContentTypeHeadeValue: String { "multipart/form-data; boundary=\(boundary)" }

    public var httpBody: Data {
        var bodyData = data
        bodyData.append("--\(boundary)--")
        return bodyData
    }

    private func disposition(_ key: String) -> String { "Content-Disposition: form-data; name=\"\(key)\"" }
}

extension Data {
    mutating func append(_ string: String, encoding: String.Encoding = .utf8) {
        guard let data = string.data(using: encoding) else { return }
        append(data)
    }
}

