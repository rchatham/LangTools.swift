//
//  Gemini.swift
//  LangTools
//
//  Created by Reid Chatham on 12/22/24.
//

import Foundation
import LangTools
import OpenAI

public final class Gemini: LangTools {
    public typealias Model = GeminiModel
    public typealias ErrorResponse = GeminiErrorResponse

    public var requestTypes: [(any LangToolsRequest) -> Bool] {
        [
            { ($0 as? OpenAI.ChatCompletionRequest).flatMap { OpenAIModel.geminiModels.contains($0.model) } ?? false },
        ]
    }

    public private(set) lazy var session: URLSession = URLSession(configuration: .default, delegate: streamManager, delegateQueue: nil)
    public let streamManager = StreamSessionManager<Gemini>()

    let openAI: OpenAI

    public init(baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!, apiKey: String) {
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

public struct GeminiErrorResponse: Error, Codable {
    public let type: String?
    public let error: APIError

    public struct APIError: Error, Codable {
        public let message: String
        public let type: String
        public let param: String?
        public let code: String?
    }
}

public enum GeminiModel: String, CaseIterable {
    // Base models
    case gemini2Flash = "gemini-2.0-flash-exp"
    case gemini15Flash = "gemini-1.5-flash"
    case gemini15Flash8B = "gemini-1.5-flash-8b"
    case gemini15Pro = "gemini-1.5-pro"
    case gemini10Pro = "gemini-1.0-pro"

    // Versioned models
    case gemini15FlashLatest = "gemini-1.5-flash-latest"
    case gemini15Flash001 = "gemini-1.5-flash-001"
    case gemini15Flash002 = "gemini-1.5-flash-002"
    case gemini15Flash8BLatest = "gemini-1.5-flash-8b-latest"
    case gemini15Flash8B001 = "gemini-1.5-flash-8b-001"
    case gemini15ProLatest = "gemini-1.5-pro-latest"
    case gemini15Pro001 = "gemini-1.5-pro-001"
    case gemini15Pro002 = "gemini-1.5-pro-002"

    public var openAIModel: OpenAIModel { OpenAIModel(customModelID: rawValue) }
}

extension OpenAIModel {
    // Base models
    public static let gemini2Flash = GeminiModel.gemini2Flash.openAIModel
    public static let gemini15Flash = GeminiModel.gemini15Flash.openAIModel
    public static let gemini15Flash8B = GeminiModel.gemini15Flash8B.openAIModel
    public static let gemini15Pro = GeminiModel.gemini15Pro.openAIModel
    public static let gemini10Pro = GeminiModel.gemini10Pro.openAIModel

    // Versioned models
    public static let gemini15FlashLatest = GeminiModel.gemini15FlashLatest.openAIModel
    public static let gemini15Flash001 = GeminiModel.gemini15Flash001.openAIModel
    public static let gemini15Flash002 = GeminiModel.gemini15Flash002.openAIModel
    public static let gemini15Flash8BLatest = GeminiModel.gemini15Flash8BLatest.openAIModel
    public static let gemini15Flash8B001 = GeminiModel.gemini15Flash8B001.openAIModel
    public static let gemini15ProLatest = GeminiModel.gemini15ProLatest.openAIModel
    public static let gemini15Pro001 = GeminiModel.gemini15Pro001.openAIModel
    public static let gemini15Pro002 = GeminiModel.gemini15Pro002.openAIModel

    /// All available Gemini models
    static let geminiModels: [OpenAIModel] = [
        .gemini2Flash,
        .gemini15Flash,
        .gemini15Flash8B,
        .gemini15Pro,
        .gemini10Pro,
        .gemini15FlashLatest,
        .gemini15Flash001,
        .gemini15Flash002,
        .gemini15Flash8BLatest,
        .gemini15Flash8B001,
        .gemini15ProLatest,
        .gemini15Pro001,
        .gemini15Pro002
    ]
}

