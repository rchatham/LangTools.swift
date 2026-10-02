import Foundation

public struct ChatGenerationSettings: Codable, Equatable, Sendable {
    public enum ValidationError: LocalizedError, Equatable {
        case invalidMaximumOutputTokens(Int)
        case invalidTemperature(Double)

        public var errorDescription: String? {
            switch self {
            case .invalidMaximumOutputTokens(let value):
                return "Maximum output tokens must be between 1 and 32,768 (received \(value))."
            case .invalidTemperature(let value):
                return "Temperature must be a finite value between 0 and 1 (received \(value))."
            }
        }
    }

    public let maxOutputTokens: Int?
    public let temperature: Double?

    public static let automatic = try! ChatGenerationSettings()
    public static let tokenRange = 1...32_768
    public static let tokenPresets = [1_024, 2_048, 4_096, 8_192, 16_384, 32_768]
    public static let temperatureRange = 0.0...1.0

    public init(maxOutputTokens: Int? = nil, temperature: Double? = nil) throws {
        if let maxOutputTokens, !Self.tokenRange.contains(maxOutputTokens) {
            throw ValidationError.invalidMaximumOutputTokens(maxOutputTokens)
        }
        if let temperature,
           (!temperature.isFinite || !Self.temperatureRange.contains(temperature)) {
            throw ValidationError.invalidTemperature(temperature)
        }
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
    }

    private enum CodingKeys: String, CodingKey {
        case maxOutputTokens
        case temperature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maxOutputTokens: container.decodeIfPresent(Int.self, forKey: .maxOutputTokens),
            temperature: container.decodeIfPresent(Double.self, forKey: .temperature)
        )
    }
}
