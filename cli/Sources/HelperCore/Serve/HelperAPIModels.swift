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

struct HelperPairingExchangeRequest: Decodable {
    let code: String
}

struct HelperPairingExchangeResponse: Codable {
    let port: Int
    let token: String
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

public struct HelperChatMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: String
}

struct HelperChatResponse: Codable {
    let content: String
}

struct HelperChatStreamEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case delta
        case complete
        case error
    }

    let type: Kind
    let delta: String?
    let content: String?
    let error: String?

    static func delta(_ value: String) -> Self {
        Self(type: .delta, delta: value, content: nil, error: nil)
    }

    static func complete(_ value: String) -> Self {
        Self(type: .complete, delta: nil, content: value, error: nil)
    }

    static func failure(_ value: String) -> Self {
        Self(type: .error, delta: nil, content: nil, error: value)
    }
}
