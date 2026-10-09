import Foundation
import Ollama

public enum OllamaEndpointError: LocalizedError, Equatable {
    case empty
    case malformed(String)
    case unsupportedScheme(String?)
    case missingHost
    case disallowedComponent(String)
    case unsafeHTTPHost(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Ollama server URL cannot be empty."
        case .malformed:
            return "Ollama server URL is malformed."
        case .unsupportedScheme:
            return "Ollama server URL must use HTTPS, or HTTP for localhost."
        case .missingHost:
            return "Ollama server URL must include a host."
        case .disallowedComponent(let component):
            return "Ollama server URL must not include a \(component)."
        case .unsafeHTTPHost:
            return "HTTP is only allowed for localhost Ollama servers. Use HTTPS for remote servers."
        }
    }
}

public enum OllamaEndpointPolicy {
    public static let userDefaultsKey = "ollamaServerUrl"
    public static let defaultURL = URL(string: "http://localhost:11434")!

    public static func resolve(userDefaults: UserDefaults = .standard) throws -> URL {
        guard let persistedValue = userDefaults.object(forKey: userDefaultsKey) else {
            return defaultURL
        }
        guard let value = persistedValue as? String else {
            throw OllamaEndpointConfiguration.ValidationError.invalidURL
        }
        return try validate(value)
    }

    public static func validate(_ value: String) throws -> URL {
        try OllamaEndpointConfiguration.validate(value)
    }

    public static func makeOllama(userDefaults: UserDefaults = .standard) throws -> Ollama {
        try makeOllama(baseURL: resolve(userDefaults: userDefaults))
    }

    public static func makeOllama(baseURL: URL) throws -> Ollama {
        let validatedURL = try validate(baseURL.absoluteString)
        return Ollama(baseURL: validatedURL, session: LoopbackURLSession.shared)
    }
}
