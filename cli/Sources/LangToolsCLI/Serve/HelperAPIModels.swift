import Foundation

struct HelperHealthResponse: Codable {
    let status: String
    let version: Int
}

struct HelperAuthRequest: Decodable {
    let provider: String
}

struct HelperAuthStatusResponse: Codable {
    let provider: String
    let authenticated: Bool
    let accountIdentifier: String?
    let expiresAt: String?
    let accessibleModelIDs: [String]?
}

struct HelperErrorResponse: Codable {
    let error: String
}

struct HelperModelsResponse: Codable {
    let models: [String]
}

struct HelperChatRequest: Decodable {
    let provider: String
    let model: String
    let messages: [HelperChatMessage]
    let stream: Bool
}

struct HelperChatMessage: Decodable {
    let role: String
    let content: String
}

struct HelperChatResponse: Codable {
    let content: String
}
