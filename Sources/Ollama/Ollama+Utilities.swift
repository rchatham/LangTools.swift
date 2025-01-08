import Foundation
import RegexBuilder

import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// A codable value.
public enum Value: Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case data(mimeType: String? = nil, Data)
    case array([Value])
    case object([String: Value])

    /// Create a `Value` from a `Codable` value.
    /// - Parameter value: The codable value
    /// - Returns: A value
    public init<T: Codable>(_ value: T) throws {
        if let valueAsValue = value as? Value {
            self = valueAsValue
        } else {
            let data = try JSONEncoder().encode(value)
            self = try JSONDecoder().decode(Value.self, from: data)
        }
    }

    /// Returns whether the value is `null`.
    public var isNull: Bool {
        return self == .null
    }

    /// Returns the `Bool` value if the value is a `bool`,
    /// otherwise returns `nil`.
    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    /// Returns the `Int` value if the value is an `integer`,
    /// otherwise returns `nil`.
    public var intValue: Int? {
        guard case let .int(value) = self else { return nil }
        return value
    }

    /// Returns the `Double` value if the value is a `double`,
    /// otherwise returns `nil`.
    public var doubleValue: Double? {
        guard case let .double(value) = self else { return nil }
        return value
    }

    /// Returns the `String` value if the value is a `string`,
    /// otherwise returns `nil`.
    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    /// Returns the data value and optional MIME type if the value is `data`,
    /// otherwise returns `nil`.
    public var dataValue: (mimeType: String?, Data)? {
        guard case let .data(mimeType: mimeType, data) = self else { return nil }
        return (mimeType: mimeType, data)
    }

    /// Returns the `[Value]` value if the value is an `array`,
    /// otherwise returns `nil`.
    public var arrayValue: [Value]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    /// Returns the `[String: Value]` value if the value is an `object`,
    /// otherwise returns `nil`.
    public var objectValue: [String: Value]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}

// MARK: - Codable

extension Value: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            if Data.isDataURL(string: value), case let (mimeType, data)? = Data.parseDataURL(value) {
                self = .data(mimeType: mimeType, data)
            } else {
                self = .string(value)
            }
        } else if let value = try? container.decode([Value].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Value].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError( in: container, debugDescription: "Value type not found")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case let .data(mimeType, value):
            try container.encode(value.dataURLEncoded(mimeType: mimeType))
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension Value: CustomStringConvertible {
    public var description: String {
        switch self {
        case .null:
            return ""
        case .bool(let value):
            return value.description
        case .int(let value):
            return value.description
        case .double(let value):
            return value.description
        case .string(let value):
            return value.description
        case let .data(mimeType, value):
            return value.dataURLEncoded(mimeType: mimeType)
        case .array(let value):
            return value.description
        case .object(let value):
            return value.description
        }
    }
}

// MARK: - ExpressibleByNilLiteral

extension Value: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

// MARK: - ExpressibleByBooleanLiteral

extension Value: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

// MARK: - ExpressibleByIntegerLiteral

extension Value: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

// MARK: - ExpressibleByFloatLiteral

extension Value: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

// MARK: - ExpressibleByStringLiteral

extension Value: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

// MARK: - ExpressibleByArrayLiteral

extension Value: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Value...) {
        self = .array(elements)
    }
}

// MARK: - ExpressibleByDictionaryLiteral

extension Value: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, Value)...) {
        var dictionary: [String: Value] = [:]
        for (key, value) in elements {
            dictionary[key] = value
        }
        self = .object(dictionary)
    }
}

// MARK: - ExpressibleByStringInterpolation

extension Value: ExpressibleByStringInterpolation {
    public struct StringInterpolation: StringInterpolationProtocol {
        var stringValue: String

        public init(literalCapacity: Int, interpolationCount: Int) {
            self.stringValue = ""
            self.stringValue.reserveCapacity(literalCapacity + interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) {
            self.stringValue.append(literal)
        }

        public mutating func appendInterpolation<T: CustomStringConvertible>(_ value: T) {
            self.stringValue.append(value.description)
        }
    }

    public init(stringInterpolation: StringInterpolation) {
        self = .string(stringInterpolation.stringValue)
    }
}

// MARK: - Standard Library Type Extensions

extension Bool {
    /// Creates a boolean value from a `Value` instance.
    ///
    /// In strict mode, only `.bool` values are converted. In non-strict mode, the following conversions are supported:
    /// - Integers: `1` is `true`, `0` is `false`
    /// - Doubles: `1.0` is `true`, `0.0` is `false`
    /// - Strings (lowercase only):
    ///   - `true`: "true", "t", "yes", "y", "on", "1"
    ///   - `false`: "false", "f", "no", "n", "off", "0"
    ///
    /// - Parameters:
    ///   - value: The `Value` to convert
    ///   - strict: When `true`, only converts from `.bool` values. Defaults to `true`
    /// - Returns: A boolean value if conversion is possible, `nil` otherwise
    ///
    /// - Example:
    ///   ```swift
    ///   Bool(Value.bool(true)) // Returns true
    ///   Bool(Value.int(1), strict: false) // Returns true
    ///   Bool(Value.string("yes"), strict: false) // Returns true
    ///   ```
    public init?(_ value: Value, strict: Bool = true) {
        switch value {
        case .bool(let b): self = b
        case .int(let i) where !strict:
            switch i {
            case 0: self = false
            case 1: self = true
            default: return nil
            }
        case .double(let d) where !strict:
            switch d {
            case 0.0: self = false
            case 1.0: self = true
            default: return nil
            }
        case .string(let s) where !strict:
            switch s {
            case "true", "t", "yes", "y", "on", "1": self = true
            case "false", "f", "no", "n", "off", "0": self = false
            default: return nil
            }
        default: return nil
        }
    }
}

extension Int {
    /// Creates an integer value from a `Value` instance.
    ///
    /// In strict mode, only `.int` values are converted. In non-strict mode, the following conversions are supported:
    /// - Doubles: Converted if they can be represented exactly as integers
    /// - Strings: Parsed if they contain a valid integer representation
    ///
    /// - Parameters:
    ///   - value: The `Value` to convert
    ///   - strict: When `true`, only converts from `.int` values. Defaults to `true`
    /// - Returns: An integer value if conversion is possible, `nil` otherwise
    ///
    /// - Example:
    ///   ```swift
    ///   Int(Value.int(42)) // Returns 42
    ///   Int(Value.double(42.0), strict: false) // Returns 42
    ///   Int(Value.string("42"), strict: false) // Returns 42
    ///   Int(Value.double(42.5), strict: false) // Returns nil
    ///   ```
    public init?(_ value: Value, strict: Bool = true) {
        switch value {
        case .int(let i): self = i
        case .double(let d) where !strict:
            guard let intValue = Int(exactly: d) else { return nil }
            self = intValue
        case .string(let s) where !strict:
            guard let intValue = Int(s) else { return nil }
            self = intValue
        default: return nil
        }
    }
}

extension Double {
    /// Creates a double value from a `Value` instance.
    ///
    /// In strict mode, converts from `.double` and `.int` values. In non-strict mode, the following conversions are supported:
    /// - Integers: Converted to their double representation
    /// - Strings: Parsed if they contain a valid floating-point representation
    ///
    /// - Parameters:
    ///   - value: The `Value` to convert
    ///   - strict: When `true`, only converts from `.double` and `.int` values. Defaults to `true`
    /// - Returns: A double value if conversion is possible, `nil` otherwise
    ///
    /// - Example:
    ///   ```swift
    ///   Double(Value.double(42.5)) // Returns 42.5
    ///   Double(Value.int(42)) // Returns 42.0
    ///   Double(Value.string("42.5"), strict: false) // Returns 42.5
    ///   ```
    public init?(_ value: Value, strict: Bool = true) {
        switch value {
        case .double(let d): self = d
        case .int(let i): self = Double(i)
        case .string(let s) where !strict:
            guard let doubleValue = Double(s) else { return nil }
            self = doubleValue
        default: return nil
        }
    }
}

extension String {
    /// Creates a string value from a `Value` instance.
    ///
    /// In strict mode, only `.string` values are converted. In non-strict mode, the following conversions are supported:
    /// - Integers: Converted to their string representation
    /// - Doubles: Converted to their string representation
    /// - Booleans: Converted to "true" or "false"
    ///
    /// - Parameters:
    ///   - value: The `Value` to convert
    ///   - strict: When `true`, only converts from `.string` values. Defaults to `true`
    /// - Returns: A string value if conversion is possible, `nil` otherwise
    ///
    /// - Example:
    ///   ```swift
    ///   String(Value.string("hello")) // Returns "hello"
    ///   String(Value.int(42), strict: false) // Returns "42"
    ///   String(Value.bool(true), strict: false) // Returns "true"
    ///   ```
    public init?(_ value: Value, strict: Bool = true) {
        switch value {
        case .string(let s): self = s
        case .int(let i) where !strict: self = String(i)
        case .double(let d) where !strict: self = String(d)
        case .bool(let b) where !strict: self = String(b)
        default: return nil
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// A custom date decoding strategy that handles ISO8601 formatted dates with optional fractional seconds.
    ///
    /// This strategy attempts to parse dates in the following order:
    /// 1. ISO8601 with fractional seconds
    /// 2. ISO8601 without fractional seconds
    ///
    /// If both parsing attempts fail, it throws a `DecodingError.dataCorruptedError`.
    ///
    /// - Returns: A `DateDecodingStrategy` that can be used with a `JSONDecoder`.
    public static let iso8601WithFractionalSeconds = custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]

        if let date = formatter.date(from: string) {
            return date
        }

        // Try again without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]

        guard let date = formatter.date(from: string) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid date: \(string)")
        }

        return date
    }
}

/// Regex pattern for data URLs
private let dataURLRegex = Regex {
    "data:"
    Capture {
        ZeroOrMore(.reluctant) {
            CharacterClass.anyOf(",;").inverted
        }
    }
    Optionally {
        ";charset="
        Capture {
            OneOrMore(.reluctant) {
                CharacterClass.anyOf(",;").inverted
            }
        }
    }
    Optionally { ";base64" }
    ","
    Capture {
        ZeroOrMore { .any }
    }
}

extension Data {
    /// Checks if a given string is a valid data URL.
    ///
    /// - Parameter string: The string to check.
    /// - Returns: `true` if the string is a valid data URL, otherwise `false`.
    /// - SeeAlso: [RFC 2397](https://www.rfc-editor.org/rfc/rfc2397.html)
    public static func isDataURL(string: String) -> Bool {
        return string.wholeMatch(of: dataURLRegex) != nil
    }

    /// Parses a data URL string into its MIME type and data components.
    ///
    /// - Parameter string: The data URL string to parse.
    /// - Returns: A tuple containing the MIME type and decoded data, or `nil` if parsing fails.
    /// - SeeAlso: [RFC 2397](https://www.rfc-editor.org/rfc/rfc2397.html)
    public static func parseDataURL(_ string: String) -> (mimeType: String, data: Data)? {
        guard let match = string.wholeMatch(of: dataURLRegex) else {
            return nil
        }

        // Extract components using strongly typed captures
        let (_, mediatype, charset, encodedData) = match.output

        let isBase64 = string.contains(";base64,")

        // Process MIME type
        var mimeType = mediatype.isEmpty ? "text/plain" : String(mediatype)
        if let charset = charset, !charset.isEmpty, mimeType.starts(with: "text/") {
            mimeType += ";charset=\(charset)"
        }

        // Decode data
        let decodedData: Data
        if isBase64 {
            guard let base64Data = Data(base64Encoded: String(encodedData)) else { return nil }
            decodedData = base64Data
        } else {
            guard
                let percentDecodedData = String(encodedData).removingPercentEncoding?.data(
                    using: .utf8)
            else { return nil }
            decodedData = percentDecodedData
        }

        return (mimeType: mimeType, data: decodedData)
    }

    /// Encodes the data as a data URL string with an optional MIME type.
    ///
    /// - Parameter mimeType: The MIME type of the data. If `nil`, "text/plain" will be used.
    /// - Returns: A data URL string representation of the data.
    /// - SeeAlso: [RFC 2397](https://www.rfc-editor.org/rfc/rfc2397.html)
    public func dataURLEncoded(mimeType: String? = nil) -> String {
        let base64Data = self.base64EncodedString()
        return "data:\(mimeType ?? "text/plain");base64,\(base64Data)"
    }
}
