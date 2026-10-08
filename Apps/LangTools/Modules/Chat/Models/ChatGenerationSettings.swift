import Foundation

public struct ChatGenerationSettings: Codable, Equatable, Sendable {
    public enum ValidationError: LocalizedError, Equatable {
        case invalidMaximumOutputTokens(Int)
        case invalidTemperature(Double)
        case invalidTopP(Double)
        case invalidFrequencyPenalty(Double)
        case invalidPresencePenalty(Double)
        case invalidTopK(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidMaximumOutputTokens(let value):
                return "Maximum output tokens must be between 1 and 1,000,000 (received \(value))."
            case .invalidTemperature(let value):
                return "Temperature must be a finite value between 0 and 1 (received \(value))."
            case .invalidTopP(let value):
                return "Top P must be a finite value between 0 and 1 (received \(value))."
            case .invalidFrequencyPenalty(let value):
                return "Frequency penalty must be a finite value between -2 and 2 (received \(value))."
            case .invalidPresencePenalty(let value):
                return "Presence penalty must be a finite value between -2 and 2 (received \(value))."
            case .invalidTopK(let value):
                return "Top K must be at least 1 (received \(value))."
            }
        }
    }

    public let maxOutputTokens: Int?
    public let temperature: Double?
    public let topP: Double?
    public let frequencyPenalty: Double?
    public let presencePenalty: Double?
    public let topK: Int?
    public let seed: Int?
    public let stop: [String]?

    public static let automatic = try! ChatGenerationSettings()
    /// A generous app-level persistence guard, not a claim about any model's output limit.
    public static let tokenRange = 1...1_000_000
    public static let tokenPresets = [
        1_024, 2_048, 4_096, 8_192, 16_384, 32_768,
        64_000, 65_536, 100_000, 128_000, 272_000,
    ]
    public static let temperatureRange = 0.0...1.0
    public static let topPRange = 0.0...1.0
    public static let penaltyRange = -2.0...2.0
    public static let topKRange = 1...Int.max

    public init(
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        topK: Int? = nil,
        seed: Int? = nil,
        stop: [String]? = nil
    ) throws {
        if let maxOutputTokens, !Self.tokenRange.contains(maxOutputTokens) {
            throw ValidationError.invalidMaximumOutputTokens(maxOutputTokens)
        }
        if let temperature,
           (!temperature.isFinite || !Self.temperatureRange.contains(temperature)) {
            throw ValidationError.invalidTemperature(temperature)
        }
        if let topP,
           (!topP.isFinite || !Self.topPRange.contains(topP)) {
            throw ValidationError.invalidTopP(topP)
        }
        if let frequencyPenalty,
           (!frequencyPenalty.isFinite || !Self.penaltyRange.contains(frequencyPenalty)) {
            throw ValidationError.invalidFrequencyPenalty(frequencyPenalty)
        }
        if let presencePenalty,
           (!presencePenalty.isFinite || !Self.penaltyRange.contains(presencePenalty)) {
            throw ValidationError.invalidPresencePenalty(presencePenalty)
        }
        if let topK, !Self.topKRange.contains(topK) {
            throw ValidationError.invalidTopK(topK)
        }
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.topK = topK
        self.seed = seed
        self.stop = stop
    }

    private enum CodingKeys: String, CodingKey {
        case maxOutputTokens
        case temperature
        case topP
        case frequencyPenalty
        case presencePenalty
        case topK
        case seed
        case stop
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maxOutputTokens: container.decodeIfPresent(Int.self, forKey: .maxOutputTokens),
            temperature: container.decodeIfPresent(Double.self, forKey: .temperature),
            topP: container.decodeIfPresent(Double.self, forKey: .topP),
            frequencyPenalty: container.decodeIfPresent(Double.self, forKey: .frequencyPenalty),
            presencePenalty: container.decodeIfPresent(Double.self, forKey: .presencePenalty),
            topK: container.decodeIfPresent(Int.self, forKey: .topK),
            seed: container.decodeIfPresent(Int.self, forKey: .seed),
            stop: container.decodeIfPresent([String].self, forKey: .stop)
        )
    }
}
