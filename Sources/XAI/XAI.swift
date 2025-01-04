//
//  XAI.swift
//  LangTools
//
//  Created by Reid Chatham on 12/22/24.
//

import Foundation
import LangTools
import OpenAI

public final class XAI: LangTools {
    public typealias Model = XAIModel
    public typealias ErrorResponse = XAIErrorResponse

    public var requestTypes: [(any LangToolsRequest) -> Bool] {
        [
            { ($0 as? OpenAI.ChatCompletionRequest).flatMap { OpenAIModel.xAIModels.contains($0.model) } ?? false },
        ]
    }

    public private(set) lazy var session: URLSession = URLSession(configuration: .default, delegate: streamManager, delegateQueue: nil)
    public let streamManager = StreamSessionManager<XAI>()

    let openAI: OpenAI

    public init(baseURL: URL = URL(string: "https://api.x.ai/v1/")!, apiKey: String) {
        openAI = OpenAI(configuration: .init(baseURL: baseURL, apiKey: apiKey))
    }

    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        session = URLSession(configuration: testURLSessionConfiguration, delegate: streamManager, delegateQueue: nil)
        return self
    }

    public func prepare(request: some LangToolsRequest) throws -> URLRequest {
        try openAI.prepare(request: request)
    }
    
    public static func processStream(data: Data, completion: @escaping (Data) -> Void) {
        OpenAI.processStream(data: data, completion: completion)
    }
}

public struct XAIErrorResponse: Error, Codable {
    public let type: String?
    public let error: APIError

    public struct APIError: Error, Codable {
        public let message: String
        public let type: String
        public let param: String?
        public let code: String?
    }
}

public enum XAIModel: String, CaseIterable {
    case grok = "grok-2-1212"
    case grokVision = "grok-2-vision-1212"

    public var openAIModel: OpenAIModel { OpenAIModel(customModelID: rawValue) }
}

extension OpenAIModel {
    public static let grok = XAIModel.grok.openAIModel
    public static let grokVision = XAIModel.grokVision.openAIModel

    static let xAIModels: [OpenAIModel] = [.grok, .grokVision]
}
