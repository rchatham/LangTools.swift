import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

enum CodexRequestID: Codable, Hashable, Sendable {
    case integer(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self = .integer(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

struct CodexRequestEnvelope<Params: Encodable>: Encodable {
    let id: CodexRequestID
    let method: String
    let params: Params
}

struct CodexNotificationEnvelope<Params: Encodable>: Encodable {
    let method: String
    let params: Params?
}

struct CodexResponseEnvelope<Result: Decodable>: Decodable {
    let id: CodexRequestID
    let result: Result?
    let error: CodexErrorEnvelope?
}

struct CodexErrorEnvelope: Codable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?
}

// Wire types mirror the Codex app-server schemas generated in /tmp/cx_ts and
// /tmp/cx_schema. Optional values are omitted by JSONEncoder unless noted.
struct CodexInitializeParams: Codable, Sendable {
    struct ClientInfo: Codable, Sendable {
        let name: String
        let title: String?
        let version: String
    }

    struct Capabilities: Codable, Sendable {
        let experimentalApi: Bool
        let requestAttestation: Bool
        let mcpServerOpenaiFormElicitation: Bool?
        let optOutNotificationMethods: [String]?
    }

    let clientInfo: ClientInfo
    let capabilities: Capabilities?
}

struct CodexInitializeResponse: Codable, Sendable {
    let userAgent: String
    let codexHome: String
    let platformFamily: String
    let platformOs: String
}

struct CodexGetAccountParams: Codable, Sendable {
    let refreshToken: Bool?
}

struct CodexGetAccountResponse: Decodable, Sendable {
    let account: CodexAccount?
    let requiresOpenaiAuth: Bool
}

enum CodexAccount: Decodable, Sendable {
    case apiKey
    case chatgpt(email: String?, planType: String)
    case amazonBedrock

    private enum CodingKeys: String, CodingKey { case type, email, planType }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "apiKey": self = .apiKey
        case "chatgpt": self = .chatgpt(
            email: try container.decodeIfPresent(String.self, forKey: .email),
            planType: try container.decode(String.self, forKey: .planType)
        )
        case "amazonBedrock": self = .amazonBedrock
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown Codex account type")
        }
    }
}

struct CodexChatGPTLoginParams: Encodable, Sendable {
    let type = "chatgpt"
    let codexStreamlinedLogin: Bool?
}

enum CodexLoginAccountResponse: Decodable, Sendable {
    case apiKey
    case chatgpt(loginId: String, authUrl: String)
    case chatgptDeviceCode(loginId: String, verificationUrl: String, userCode: String)
    case chatgptAuthTokens

    private enum CodingKeys: String, CodingKey {
        case type, loginId, authUrl, verificationUrl, userCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "apiKey": self = .apiKey
        case "chatgpt": self = .chatgpt(
            loginId: try container.decode(String.self, forKey: .loginId),
            authUrl: try container.decode(String.self, forKey: .authUrl)
        )
        case "chatgptDeviceCode": self = .chatgptDeviceCode(
            loginId: try container.decode(String.self, forKey: .loginId),
            verificationUrl: try container.decode(String.self, forKey: .verificationUrl),
            userCode: try container.decode(String.self, forKey: .userCode)
        )
        case "chatgptAuthTokens": self = .chatgptAuthTokens
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown Codex login response type")
        }
    }
}

struct CodexCancelLoginAccountParams: Codable, Sendable { let loginId: String }
struct CodexCancelLoginAccountResponse: Decodable, Sendable { let status: String }
struct CodexLogoutAccountResponse: Decodable, Sendable {}

struct CodexAccountLoginCompletedNotification: Decodable, Sendable {
    let loginId: String?
    let success: Bool
    let error: String?
}

struct CodexModelListParams: Codable, Sendable {
    let cursor: String?
    let limit: Int?
    let includeHidden: Bool?
}

struct CodexModelListResponse: Decodable, Sendable {
    let data: [CodexModel]
    let nextCursor: String?
}

struct CodexModel: Decodable, Sendable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let hidden: Bool
    let isDefault: Bool
}

struct CodexThreadStartParams: Encodable, Sendable {
    let model: String?
    let modelProvider: String?
    let cwd: String?
    let approvalPolicy: String?
    let sandbox: String?
    let config: [String: JSONValue]?
    let developerInstructions: String?
    let multiAgentMode: String?
    let ephemeral: Bool?
    let environments: [CodexTurnEnvironmentParams]?
    let dynamicTools: [CodexDynamicToolSpec]?
    let selectedCapabilityRoots: [CodexSelectedCapabilityRoot]?
}

struct CodexTurnEnvironmentParams: Codable, Sendable {
    let cwd: String
    let environmentId: String
}

struct CodexDynamicToolSpec: Codable, Sendable {}
struct CodexSelectedCapabilityRoot: Codable, Sendable {}

struct CodexThreadStartResponse: Decodable, Sendable {
    struct Thread: Decodable, Sendable { let id: String }
    let thread: Thread
    let model: String
    let modelProvider: String
}

struct CodexTurnStartParams: Encodable, Sendable {
    struct UserInput: Encodable, Sendable {
        let type = "text"
        let text: String
        let textElements: [TextElement] = []

        enum CodingKeys: String, CodingKey {
            case type, text
            case textElements = "text_elements"
        }
    }

    struct TextElement: Codable, Sendable {}

    let threadId: String
    let input: [UserInput]
    let approvalPolicy: String?
    let sandboxPolicy: ReadOnlySandboxPolicy?
    let model: String?
    let environments: [CodexTurnEnvironmentParams]?
    let multiAgentMode: String?
}

struct ReadOnlySandboxPolicy: Encodable, Sendable {
    let type = "readOnly"
    let networkAccess = false
}

struct CodexTurnStartResponse: Decodable, Sendable {
    struct Turn: Decodable, Sendable { let id: String }
    let turn: Turn
}

struct CodexTurnInterruptParams: Codable, Sendable {
    let threadId: String
    let turnId: String
}

struct CodexAgentMessageDeltaNotification: Decodable, Sendable {
    let threadId: String
    let turnId: String
    let itemId: String
    let delta: String
}

struct CodexTurnError: Decodable, Sendable {
    let message: String
    let additionalDetails: String?
    let codexErrorInfo: CodexErrorInfo?
}

enum CodexErrorCode: String, Decodable, Sendable {
    case contextWindowExceeded
    case usageLimitExceeded
    case serverOverloaded
    case cyberPolicy
    case internalServerError
    case unauthorized
    case badRequest
    case threadRollbackFailed
    case sandboxError
    case other
}

enum CodexNonSteerableTurnKind: String, Decodable, Sendable {
    case review
    case compact
}

enum CodexErrorInfo: Decodable, Sendable {
    case code(CodexErrorCode)
    case httpConnectionFailed(httpStatusCode: Int?)
    case responseStreamConnectionFailed(httpStatusCode: Int?)
    case responseStreamDisconnected(httpStatusCode: Int?)
    case responseTooManyFailedAttempts(httpStatusCode: Int?)
    case activeTurnNotSteerable(turnKind: CodexNonSteerableTurnKind)
    case unknown(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let rawCode = try? container.decode(String.self) {
            self = CodexErrorCode(rawValue: rawCode).map(Self.code) ?? .unknown(rawCode)
            return
        }

        let object = try container.decode([String: JSONValue].self)
        guard object.count == 1, let entry = object.first else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected one exact codexErrorInfo variant")
        }
        switch entry.key {
        case "httpConnectionFailed":
            self = .httpConnectionFailed(httpStatusCode: try Self.httpStatus(from: entry.value, in: container))
        case "responseStreamConnectionFailed":
            self = .responseStreamConnectionFailed(httpStatusCode: try Self.httpStatus(from: entry.value, in: container))
        case "responseStreamDisconnected":
            self = .responseStreamDisconnected(httpStatusCode: try Self.httpStatus(from: entry.value, in: container))
        case "responseTooManyFailedAttempts":
            self = .responseTooManyFailedAttempts(httpStatusCode: try Self.httpStatus(from: entry.value, in: container))
        case "activeTurnNotSteerable":
            guard case .object(let details) = entry.value,
                  details.count == 1,
                  case .string(let rawKind)? = details["turnKind"],
                  let kind = CodexNonSteerableTurnKind(rawValue: rawKind)
            else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid activeTurnNotSteerable details")
            }
            self = .activeTurnNotSteerable(turnKind: kind)
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown codexErrorInfo variant: \(entry.key)")
        }
    }

    private static func httpStatus(
        from value: JSONValue,
        in container: SingleValueDecodingContainer
    ) throws -> Int? {
        guard case .object(let details) = value,
              details.keys.allSatisfy({ $0 == "httpStatusCode" })
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid transport codexErrorInfo details")
        }
        switch details["httpStatusCode"] {
        case .number(let number): return Int(number)
        case .null, nil: return nil
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Codex HTTP status")
        }
    }
}

struct CodexTurnCompletedNotification: Decodable, Sendable {
    struct Turn: Decodable, Sendable {
        let id: String
        let status: String
        let error: CodexTurnError?
    }
    let threadId: String
    let turn: Turn
}

struct CodexErrorNotification: Decodable, Sendable {
    let error: CodexTurnError
    let willRetry: Bool
    let threadId: String
    let turnId: String
}

struct CodexServerNotification: Sendable {
    let method: String
    let params: Data
}

struct CodexEmptyParams: Codable, Sendable {}
