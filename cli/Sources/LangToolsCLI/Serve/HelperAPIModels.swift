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
    let conversationID: UUID?

    private enum CodingKeys: String, CodingKey {
        case provider, model, messages, stream, conversationID
    }

    private static let securityFieldNames: Set<String> = [
        "cwd", "currentdirectory", "currentworkingdirectory", "workingdirectory",
        "sandbox", "sandboxpolicy", "permissions", "permissionprofile",
        "approvalpolicy", "approvalsreviewer", "networkaccess",
        "writableroots", "workspaceroots", "runtimeworkspaceroots",
        "selectedcapabilityroots", "dynamictools", "config",
        "developerinstructions", "baseinstructions", "environment", "environments",
        "multiagentmode", "modelprovider", "ephemeral", "personality",
        "collaborationmode"
    ]

    init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: HelperCodingKey.self)
        let rejected = allFields.allKeys.map(\.stringValue).filter {
            Self.securityFieldNames.contains(Self.normalizedFieldName($0))
        }
        guard rejected.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Security-sensitive chat request fields are not accepted: \(rejected.sorted().joined(separator: ", "))")
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        messages = try container.decode([HelperChatMessage].self, forKey: .messages)
        stream = try container.decode(Bool.self, forKey: .stream)
        conversationID = try container.decodeIfPresent(UUID.self, forKey: .conversationID)
    }

    private static func normalizedFieldName(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}

private struct HelperCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct HelperChatMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String
}

struct HelperChatResponse: Codable {
    let content: String
}
