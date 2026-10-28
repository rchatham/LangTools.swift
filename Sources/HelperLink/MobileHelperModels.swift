import Foundation

public enum MobileHelperLinkError: Error, LocalizedError {
    case invalidPayload
    public var errorDescription: String? { "Invalid or unsupported mobile helper pairing link." }
}

/// The QR is an explicit identity bootstrap, not a reusable device credential.
public struct MobileHelperPairingPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let endpoint: URL
    public let helperID: String
    public let fingerprint: String
    public let code: String
    public let name: String

    public init(version: Int = 1, endpoint: URL, helperID: String, fingerprint: String, code: String, name: String) {
        self.version = version
        self.endpoint = endpoint
        self.helperID = helperID
        self.fingerprint = fingerprint
        self.code = code
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case version, endpoint, helperID, fingerprint, code, name }

    public init(from decoder: Decoder) throws {
        try requireKeys(decoder, ["version", "endpoint", "helperID", "fingerprint", "code", "name"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        endpoint = try container.decode(URL.self, forKey: .endpoint)
        helperID = try container.decode(String.self, forKey: .helperID)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        code = try container.decode(String.self, forKey: .code)
        name = try container.decode(String.self, forKey: .name)
        try validate()
    }

    public func validate() throws {
        guard version == 1, UUID(uuidString: helperID) != nil,
              Self.isHexSecret(fingerprint), Self.isHexSecret(code), Self.isDisplayName(name),
              let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path == "" || components.path == "/",
              let host = components.host, Self.isPrivateIPv4(host),
              let port = components.port, (1...65535).contains(port)
        else { throw MobileHelperLinkError.invalidPayload }
    }

    public static func parse(_ url: URL) throws -> Self {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "langtools-example-auth", components.host == "helper",
              components.path == "/pair", components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 6
        else { throw MobileHelperLinkError.invalidPayload }
        var fields: [String: String] = [:]
        let keys: Set<String> = ["v", "endpoint", "identity", "fingerprint", "code", "name"]
        for item in items {
            guard keys.contains(item.name), fields[item.name] == nil, let value = item.value else {
                throw MobileHelperLinkError.invalidPayload
            }
            fields[item.name] = value
        }
        guard fields["v"] == "1", let endpointText = fields["endpoint"], let endpoint = URL(string: endpointText),
              let identity = fields["identity"], let fingerprint = fields["fingerprint"],
              let code = fields["code"], let name = fields["name"]
        else { throw MobileHelperLinkError.invalidPayload }
        let payload = Self(endpoint: endpoint, helperID: identity, fingerprint: fingerprint, code: code, name: name)
        try payload.validate()
        return payload
    }

    public func pairingURL() throws -> URL {
        try validate()
        var components = URLComponents()
        components.scheme = "langtools-example-auth"
        components.host = "helper"
        components.path = "/pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "endpoint", value: endpoint.absoluteString),
            URLQueryItem(name: "identity", value: helperID), URLQueryItem(name: "fingerprint", value: fingerprint),
            URLQueryItem(name: "code", value: code), URLQueryItem(name: "name", value: name)
        ]
        guard let url = components.url else { throw MobileHelperLinkError.invalidPayload }
        return url
    }

    public static func isHexSecret(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func isDisplayName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// Canonical dotted decimal only: excludes loopback, multicast, public IPs and ambiguous octal spellings.
    /// A suffix of .0 or .255 can be a valid host; network/broadcast addresses depend on the subnet mask.
    public static func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var bytes: [Int] = []
        for part in parts {
            guard let byte = Int(part), (0...255).contains(byte), String(byte) == part else { return false }
            bytes.append(byte)
        }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 169 && bytes[1] == 254 && (1...254).contains(bytes[2]))
    }
}

public struct MobileHelperPairingRequest: Codable, Equatable, Sendable {
    public let code: String
    public let name: String
    public init(code: String, name: String) { self.code = code; self.name = name }
    private enum CodingKeys: String, CodingKey { case code, name }
    public init(from decoder: Decoder) throws {
        try requireKeys(decoder, ["code", "name"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        name = try container.decode(String.self, forKey: .name)
        try validate()
    }
    public func validate() throws {
        guard MobileHelperPairingPayload.isHexSecret(code), MobileHelperPairingPayload.isDisplayName(name) else {
            throw MobileHelperLinkError.invalidPayload
        }
    }
}

public struct MobileHelperPairingResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let helperID: String
    public let deviceID: String
    public let token: String
    public let capabilities: [String]
    public init(version: Int = 1, helperID: String, deviceID: String, token: String, capabilities: [String] = ["ollama"]) {
        self.version = version; self.helperID = helperID; self.deviceID = deviceID
        self.token = token; self.capabilities = capabilities
    }
    private enum CodingKeys: String, CodingKey { case version, helperID, deviceID, token, capabilities }
    public init(from decoder: Decoder) throws {
        try requireKeys(decoder, ["version", "helperID", "deviceID", "token", "capabilities"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        helperID = try container.decode(String.self, forKey: .helperID)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        token = try container.decode(String.self, forKey: .token)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        try validate()
    }
    public func validate() throws {
        guard version == 1, UUID(uuidString: helperID) != nil, UUID(uuidString: deviceID) != nil,
              MobileHelperPairingPayload.isHexSecret(token), capabilities == ["ollama"] else {
            throw MobileHelperLinkError.invalidPayload
        }
    }
}

public struct MobileHelperHealthResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let helperID: String
    public let capabilities: [String]
    public init(version: Int = 1, helperID: String, capabilities: [String] = ["ollama"]) {
        self.version = version; self.helperID = helperID; self.capabilities = capabilities
    }
    private enum CodingKeys: String, CodingKey { case version, helperID, capabilities }
    public init(from decoder: Decoder) throws {
        try requireKeys(decoder, ["version", "helperID", "capabilities"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        helperID = try container.decode(String.self, forKey: .helperID)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        try validate()
    }
    public func validate() throws {
        guard version == 1, UUID(uuidString: helperID) != nil, capabilities == ["ollama"] else {
            throw MobileHelperLinkError.invalidPayload
        }
    }
}

private struct WireKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let container = try decoder.container(keyedBy: WireKey.self)
    guard Set(container.allKeys.map(\.stringValue)) == expected else { throw MobileHelperLinkError.invalidPayload }
}
