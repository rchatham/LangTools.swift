//
//  LangTools+JSON.swift
//  LangTools
//
//  Created by Reid Chatham on 2/10/25.
//

import Foundation

public enum JSON: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSON])
    case array([JSON])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        do {
            let string = try container.decode(String.self)
            self = .string(string)
            return
        } catch {}

        do {
            let number = try container.decode(Double.self)
            self = .number(number)
            return
        } catch {}

        do {
            let bool = try container.decode(Bool.self)
            self = .bool(bool)
            return
        } catch {}

        do {
            let object = try container.decode([String: JSON].self)
            self = .object(object)
            return
        } catch {}

        do {
            let array = try container.decode([JSON].self)
            self = .array(array)
            return
        } catch {}

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unable to decode JSON value"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

// Convenience initializers
extension JSON {
    public init(string: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw JSONError.invalidValue("Unable to convert string to UTF-8 data")
        }

        let decoder = JSONDecoder()
        self = try decoder.decode(JSON.self, from: data)
    }

    public init(_ value: Any?) throws {
        if value == nil {
            self = .null
            return
        }

        switch value {
        case let string as String:
            self = .string(string)
        case let number as Double:
            self = .number(number)
        case let number as Int:
            self = .number(Double(number))
        case let bool as Bool:
            self = .bool(bool)
        case let array as [Any?]:
            self = .array(try array.map { try JSON($0) })
        case let dict as [String: Any?]:
            var jsonDict: [String: JSON] = [:]
            for (key, value) in dict {
                jsonDict[key] = try JSON(value)
            }
            self = .object(jsonDict)
        default:
            throw JSONError.unsupportedType(String(describing: type(of: value)))
        }
    }
}

// Value extraction methods
extension JSON {
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: JSON]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var isNull: Bool {
        guard case .null = self else { return false }
        return true
    }

    public var jsonString: String? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

// Subscript access
extension JSON {
    public subscript(key: String) -> JSON? {
        get {
            guard case .object(let dict) = self else { return nil }
            return dict[key]
        }
    }

    public subscript(index: Int) -> JSON? {
        get {
            guard case .array(let array) = self else { return nil }
            guard index >= 0 && index < array.count else { return nil }
            return array[index]
        }
    }
}

// Custom errors
public enum JSONError: Error {
    case unsupportedType(String)
    case invalidValue(String)
    case keyNotFound(String)
    case indexOutOfBounds(Int)
}

// Convert to JSONSerialization-compatible type
extension JSON {
    var jsonCompatible: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues { $0.jsonCompatible }
        case .array(let value): return value.map { $0.jsonCompatible }
        case .null: return NSNull()
        }
    }
}

// Dictionary extension for JSON serialization
extension Dictionary where Key == String, Value == JSON {
    public var string: String? {
        let jsonCompatibleDict = self.mapValues { $0.jsonCompatible }
        return (try? JSONSerialization.data(withJSONObject: jsonCompatibleDict, options: [.fragmentsAllowed, .prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }
}

// Equatable conformance
extension JSON {
    public static func ==(lhs: JSON, rhs: JSON) -> Bool {
        switch (lhs, rhs) {
        case (.string(let l), .string(let r)): return l == r
        case (.number(let l), .number(let r)): return l == r
        case (.bool(let l), .bool(let r)): return l == r
        case (.object(let l), .object(let r)): return l == r
        case (.array(let l), .array(let r)): return l == r
        case (.null, .null): return true
        default: return false
        }
    }
}
