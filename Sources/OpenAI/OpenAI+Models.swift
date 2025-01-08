//
//  OpenAI+Models.swift
//  LangTools
//
//  Created by Reid Chatham on 1/8/25.
//
import LangTools


extension OpenAI {
    public struct ModelData: Codable {
        public var id: String
        public var created: Int
        public var object: String = "model"
        public var owned_by: String
    }

    public struct ListModelDataRequest: Encodable, LangToolsRequest {
        public typealias Response = ListModelDataResponse
        public typealias LangTool = OpenAI
        public static var endpoint: String { "models" }
        public static var httpMethod: HTTPMethod { .get }

        public struct ListModelDataResponse: Decodable {
            public var object: String
            public var data: [ModelData]
        }
    }

    public struct RetrieveModelRequest: Encodable, LangToolsRequest {
        public typealias Response = ModelData
        public typealias LangTool = OpenAI
        public static var endpoint: String { "models" }
        public static var httpMethod: HTTPMethod { .get }
        public var model: String
    }

    public struct DeleteFineTunedModelRequest: Encodable, LangToolsRequest {
        public typealias Response = ModelData
        public typealias LangTool = OpenAI
        public static var endpoint: String { "models" }
        public static var httpMethod: HTTPMethod { .delete }
        public var model: String

        public struct DeleteFineTunedModelResponse: Decodable {
            public var id: String
            public var object: String
            public var deleted: Bool
        }
    }
}
