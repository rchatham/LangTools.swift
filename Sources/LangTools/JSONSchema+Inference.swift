//
//  JSONSchema+Inference.swift
//  LangTools
//
//  Provides `JSONSchema.infer(from:)`: drives a `Decodable` type's synthesised
//  `init(from:)` with a schema-recording decoder to automatically produce a
//  `JSONSchema` without any manual annotation.
//

import Foundation

// MARK: - Public API

public extension JSONSchema {
    /// Infers a ``JSONSchema`` from a `Decodable` type by driving its synthesised
    /// `init(from:)` with a schema-recording decoder.
    ///
    /// **Supported property types**
    ///
    /// | Swift type | Schema kind |
    /// |---|---|
    /// | `String` | `.string()` |
    /// | `Bool` | `.boolean()` |
    /// | `Int`, `Int8/16/32/64`, `UInt`, `UInt8/16/32/64` | `.integer()` |
    /// | `Float`, `Double` | `.number()` |
    /// | `Date` | `.string(description: "ISO 8601 date string")` |
    /// | `UUID` | `.string(description: "UUID")` |
    /// | `URL` | `.string(description: "URL")` |
    /// | `Data` | `.string(description: "base64-encoded data")` |
    /// | `Optional<T>` | schema for `T`, not required |
    /// | `[T]` | `.array(items: infer(T.self))` |
    /// | nested `Decodable` struct | `.object(…)` recursively inferred |
    ///
    /// **Limitations**
    /// - `enum` types whose `init(rawValue:)` is strict (rejects the zero/empty seed)
    ///   are inferred as `.string()` or `.integer()` based on their raw type.
    /// - `enum` types with associated values are inferred as `.string()`.
    /// - Types with custom `init(from:)` that validate their input may be inferred
    ///   as `.object(properties: [:])`. Use explicit `StructuredOutput` conformance for
    ///   those types.
    static func infer<T: Decodable>(from type: T.Type) -> JSONSchema {
        let recorder = _SchemaRecorder()
        _ = try? T(from: recorder)
        return recorder.schema
    }
}

// MARK: - _SchemaRecorder

/// Records which container type was used and accumulates property schemas.
final class _SchemaRecorder: Decoder {
    var codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    var properties: [String: JSONSchema] = [:]
    var requiredKeys: [String] = []

    enum _Kind { case none, keyed, unkeyed(JSONSchema?), singleValue(JSONSchema?) }
    var kind: _Kind = .none

    init(codingPath: [CodingKey] = []) { self.codingPath = codingPath }

    var schema: JSONSchema {
        switch kind {
        case .none, .keyed:
            return .object(
                properties: properties,
                required: requiredKeys.isEmpty ? nil : requiredKeys,
                additionalProperties: false
            )
        case .unkeyed(let item):
            return .array(items: item ?? .string())
        case .singleValue(let s):
            return s ?? .string()
        }
    }

    func record(key: String, schema: JSONSchema, required: Bool) {
        properties[key] = schema
        if required { requiredKeys.append(key) }
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        kind = .keyed
        return KeyedDecodingContainer(_SchemaKeyedContainer<Key>(recorder: self))
    }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer { _SchemaUnkeyedContainer(recorder: self) }
    func singleValueContainer() throws -> SingleValueDecodingContainer { _SchemaSingleValueContainer(recorder: self) }
}

// MARK: - _SchemaKeyedContainer

struct _SchemaKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let recorder: _SchemaRecorder
    var codingPath: [CodingKey] { recorder.codingPath }
    var allKeys: [Key] { [] }

    func contains(_ key: Key) -> Bool { true }
    func decodeNil(forKey key: Key) throws -> Bool { false }

    // Primitives – required
    func decode(_ t: Bool.Type,   forKey k: Key) throws -> Bool   { recorder.record(key: k.stringValue, schema: .boolean(),  required: true); return false }
    func decode(_ t: String.Type, forKey k: Key) throws -> String  { recorder.record(key: k.stringValue, schema: .string(),   required: true); return "" }
    func decode(_ t: Double.Type, forKey k: Key) throws -> Double  { recorder.record(key: k.stringValue, schema: .number(),   required: true); return 0 }
    func decode(_ t: Float.Type,  forKey k: Key) throws -> Float   { recorder.record(key: k.stringValue, schema: .number(),   required: true); return 0 }
    func decode(_ t: Int.Type,    forKey k: Key) throws -> Int     { recorder.record(key: k.stringValue, schema: .integer(),  required: true); return 0 }
    func decode(_ t: Int8.Type,   forKey k: Key) throws -> Int8    { recorder.record(key: k.stringValue, schema: .integer(),  required: true); return 0 }
    func decode(_ t: Int16.Type,  forKey k: Key) throws -> Int16   { recorder.record(key: k.stringValue, schema: .integer(),  required: true); return 0 }
    func decode(_ t: Int32.Type,  forKey k: Key) throws -> Int32   { recorder.record(key: k.stringValue, schema: .integer(),  required: true); return 0 }
    func decode(_ t: Int64.Type,  forKey k: Key) throws -> Int64   { recorder.record(key: k.stringValue, schema: .integer(),  required: true); return 0 }
    func decode(_ t: UInt.Type,   forKey k: Key) throws -> UInt    { recorder.record(key: k.stringValue, schema: .integer(),  required: true); return 0 }
    func decode(_ t: UInt8.Type,  forKey k: Key) throws -> UInt8   { recorder.record(key: k.stringValue, schema: .integer(),  required: true); return 0 }
    func decode(_ t: UInt16.Type, forKey k: Key) throws -> UInt16  { recorder.record(key: k.stringValue, schema: .integer(),  required: true); return 0 }
    func decode(_ t: UInt32.Type, forKey k: Key) throws -> UInt32  { recorder.record(key: k.stringValue, schema: .integer(),  required: true); return 0 }
    func decode(_ t: UInt64.Type, forKey k: Key) throws -> UInt64  { recorder.record(key: k.stringValue, schema: .integer(),  required: true); return 0 }

    // Generic Decodable – required
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        recorder.record(key: key.stringValue, schema: _inferSchema(for: type), required: true)
        return try _zeroValue(for: type, codingPath: codingPath + [key])
    }

    // Primitives – optional (not required)
    func decodeIfPresent(_ t: Bool.Type,   forKey k: Key) throws -> Bool?   { recorder.record(key: k.stringValue, schema: .boolean(),  required: false); return nil }
    func decodeIfPresent(_ t: String.Type, forKey k: Key) throws -> String?  { recorder.record(key: k.stringValue, schema: .string(),   required: false); return nil }
    func decodeIfPresent(_ t: Double.Type, forKey k: Key) throws -> Double?  { recorder.record(key: k.stringValue, schema: .number(),   required: false); return nil }
    func decodeIfPresent(_ t: Float.Type,  forKey k: Key) throws -> Float?   { recorder.record(key: k.stringValue, schema: .number(),   required: false); return nil }
    func decodeIfPresent(_ t: Int.Type,    forKey k: Key) throws -> Int?     { recorder.record(key: k.stringValue, schema: .integer(),  required: false); return nil }
    func decodeIfPresent(_ t: Int8.Type,   forKey k: Key) throws -> Int8?    { recorder.record(key: k.stringValue, schema: .integer(),  required: false); return nil }
    func decodeIfPresent(_ t: Int16.Type,  forKey k: Key) throws -> Int16?   { recorder.record(key: k.stringValue, schema: .integer(),  required: false); return nil }
    func decodeIfPresent(_ t: Int32.Type,  forKey k: Key) throws -> Int32?   { recorder.record(key: k.stringValue, schema: .integer(),  required: false); return nil }
    func decodeIfPresent(_ t: Int64.Type,  forKey k: Key) throws -> Int64?   { recorder.record(key: k.stringValue, schema: .integer(),  required: false); return nil }
    func decodeIfPresent(_ t: UInt.Type,   forKey k: Key) throws -> UInt?    { recorder.record(key: k.stringValue, schema: .integer(),  required: false); return nil }
    func decodeIfPresent(_ t: UInt8.Type,  forKey k: Key) throws -> UInt8?   { recorder.record(key: k.stringValue, schema: .integer(),  required: false); return nil }
    func decodeIfPresent(_ t: UInt16.Type, forKey k: Key) throws -> UInt16?  { recorder.record(key: k.stringValue, schema: .integer(),  required: false); return nil }
    func decodeIfPresent(_ t: UInt32.Type, forKey k: Key) throws -> UInt32?  { recorder.record(key: k.stringValue, schema: .integer(),  required: false); return nil }
    func decodeIfPresent(_ t: UInt64.Type, forKey k: Key) throws -> UInt64?  { recorder.record(key: k.stringValue, schema: .integer(),  required: false); return nil }

    // Generic Decodable – optional
    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        recorder.record(key: key.stringValue, schema: _inferSchema(for: type), required: false)
        return nil
    }

    // Nested containers
    func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type, forKey key: Key) throws -> KeyedDecodingContainer<NK> {
        let child = _SchemaRecorder(codingPath: codingPath + [key])
        recorder.record(key: key.stringValue, schema: child.schema, required: true)
        return KeyedDecodingContainer(_SchemaKeyedContainer<NK>(recorder: child))
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let child = _SchemaRecorder(codingPath: codingPath + [key])
        recorder.record(key: key.stringValue, schema: child.schema, required: true)
        return _SchemaUnkeyedContainer(recorder: child)
    }
    func superDecoder() throws -> Decoder { recorder }
    func superDecoder(forKey key: Key) throws -> Decoder { recorder }
}

// MARK: - _SchemaUnkeyedContainer

/// Decodes exactly one element so `[T].init(from:)` reveals the item type.
final class _SchemaUnkeyedContainer: UnkeyedDecodingContainer {
    let recorder: _SchemaRecorder
    var codingPath: [CodingKey] { recorder.codingPath }
    var count: Int? { 1 }
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex >= 1 }

    init(recorder: _SchemaRecorder) { self.recorder = recorder }

    // Returning `false` (not nil) without advancing is the correct no-op.
    func decodeNil() throws -> Bool { false }

    func decode(_ t: Bool.Type)   throws -> Bool   { setItemKind(.boolean());  currentIndex += 1; return false }
    func decode(_ t: String.Type) throws -> String  { setItemKind(.string());   currentIndex += 1; return "" }
    func decode(_ t: Double.Type) throws -> Double  { setItemKind(.number());   currentIndex += 1; return 0 }
    func decode(_ t: Float.Type)  throws -> Float   { setItemKind(.number());   currentIndex += 1; return 0 }
    func decode(_ t: Int.Type)    throws -> Int     { setItemKind(.integer());  currentIndex += 1; return 0 }
    func decode(_ t: Int8.Type)   throws -> Int8    { setItemKind(.integer());  currentIndex += 1; return 0 }
    func decode(_ t: Int16.Type)  throws -> Int16   { setItemKind(.integer());  currentIndex += 1; return 0 }
    func decode(_ t: Int32.Type)  throws -> Int32   { setItemKind(.integer());  currentIndex += 1; return 0 }
    func decode(_ t: Int64.Type)  throws -> Int64   { setItemKind(.integer());  currentIndex += 1; return 0 }
    func decode(_ t: UInt.Type)   throws -> UInt    { setItemKind(.integer());  currentIndex += 1; return 0 }
    func decode(_ t: UInt8.Type)  throws -> UInt8   { setItemKind(.integer());  currentIndex += 1; return 0 }
    func decode(_ t: UInt16.Type) throws -> UInt16  { setItemKind(.integer());  currentIndex += 1; return 0 }
    func decode(_ t: UInt32.Type) throws -> UInt32  { setItemKind(.integer());  currentIndex += 1; return 0 }
    func decode(_ t: UInt64.Type) throws -> UInt64  { setItemKind(.integer());  currentIndex += 1; return 0 }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        setItemKind(_inferSchema(for: type))
        currentIndex += 1
        return try _zeroValue(for: type, codingPath: codingPath)
    }

    func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type) throws -> KeyedDecodingContainer<NK> {
        let child = _SchemaRecorder(codingPath: codingPath)
        setItemKind(child.schema); currentIndex += 1
        return KeyedDecodingContainer(_SchemaKeyedContainer<NK>(recorder: child))
    }
    func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let child = _SchemaRecorder(codingPath: codingPath)
        setItemKind(child.schema); currentIndex += 1
        return _SchemaUnkeyedContainer(recorder: child)
    }
    func superDecoder() throws -> Decoder { recorder }

    private func setItemKind(_ schema: JSONSchema) {
        recorder.kind = .unkeyed(schema)
    }
}

// MARK: - _SchemaSingleValueContainer

struct _SchemaSingleValueContainer: SingleValueDecodingContainer {
    let recorder: _SchemaRecorder
    var codingPath: [CodingKey] { recorder.codingPath }

    func decodeNil() -> Bool { recorder.kind = .singleValue(.null()); return false }
    func decode(_ t: Bool.Type)   throws -> Bool   { recorder.kind = .singleValue(.boolean());  return false }
    func decode(_ t: String.Type) throws -> String  { recorder.kind = .singleValue(.string());   return "" }
    func decode(_ t: Double.Type) throws -> Double  { recorder.kind = .singleValue(.number());   return 0 }
    func decode(_ t: Float.Type)  throws -> Float   { recorder.kind = .singleValue(.number());   return 0 }
    func decode(_ t: Int.Type)    throws -> Int     { recorder.kind = .singleValue(.integer());  return 0 }
    func decode(_ t: Int8.Type)   throws -> Int8    { recorder.kind = .singleValue(.integer());  return 0 }
    func decode(_ t: Int16.Type)  throws -> Int16   { recorder.kind = .singleValue(.integer());  return 0 }
    func decode(_ t: Int32.Type)  throws -> Int32   { recorder.kind = .singleValue(.integer());  return 0 }
    func decode(_ t: Int64.Type)  throws -> Int64   { recorder.kind = .singleValue(.integer());  return 0 }
    func decode(_ t: UInt.Type)   throws -> UInt    { recorder.kind = .singleValue(.integer());  return 0 }
    func decode(_ t: UInt8.Type)  throws -> UInt8   { recorder.kind = .singleValue(.integer());  return 0 }
    func decode(_ t: UInt16.Type) throws -> UInt16  { recorder.kind = .singleValue(.integer());  return 0 }
    func decode(_ t: UInt32.Type) throws -> UInt32  { recorder.kind = .singleValue(.integer());  return 0 }
    func decode(_ t: UInt64.Type) throws -> UInt64  { recorder.kind = .singleValue(.integer());  return 0 }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let schema = _inferSchema(for: type)
        recorder.kind = .singleValue(schema)
        return try _zeroValue(for: type, codingPath: codingPath)
    }
}

// MARK: - _ZeroDecoder

/// Returns safe dummy values for every type, allowing the outer `Decodable.init(from:)` to
/// succeed after schema inference so no properties are skipped due to a mid-sequence throw.
final class _ZeroDecoder: Decoder {
    var codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]
    init(codingPath: [CodingKey] = []) { self.codingPath = codingPath }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(_ZeroKeyedContainer<Key>(codingPath: codingPath))
    }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer { _ZeroUnkeyedContainer(codingPath: codingPath) }
    func singleValueContainer() throws -> SingleValueDecodingContainer { _ZeroSingleValueContainer(codingPath: codingPath) }
}

struct _ZeroKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    var codingPath: [CodingKey]
    var allKeys: [Key] { [] }

    func contains(_ key: Key) -> Bool { true }
    func decodeNil(forKey key: Key) throws -> Bool { true }

    func decode(_ t: Bool.Type,   forKey k: Key) throws -> Bool   { false }
    func decode(_ t: String.Type, forKey k: Key) throws -> String  { "" }
    func decode(_ t: Double.Type, forKey k: Key) throws -> Double  { 0 }
    func decode(_ t: Float.Type,  forKey k: Key) throws -> Float   { 0 }
    func decode(_ t: Int.Type,    forKey k: Key) throws -> Int     { 0 }
    func decode(_ t: Int8.Type,   forKey k: Key) throws -> Int8    { 0 }
    func decode(_ t: Int16.Type,  forKey k: Key) throws -> Int16   { 0 }
    func decode(_ t: Int32.Type,  forKey k: Key) throws -> Int32   { 0 }
    func decode(_ t: Int64.Type,  forKey k: Key) throws -> Int64   { 0 }
    func decode(_ t: UInt.Type,   forKey k: Key) throws -> UInt    { 0 }
    func decode(_ t: UInt8.Type,  forKey k: Key) throws -> UInt8   { 0 }
    func decode(_ t: UInt16.Type, forKey k: Key) throws -> UInt16  { 0 }
    func decode(_ t: UInt32.Type, forKey k: Key) throws -> UInt32  { 0 }
    func decode(_ t: UInt64.Type, forKey k: Key) throws -> UInt64  { 0 }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try _zeroValue(for: type, codingPath: codingPath + [key])
    }
    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? { nil }

    func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type, forKey key: Key) throws -> KeyedDecodingContainer<NK> {
        KeyedDecodingContainer(_ZeroKeyedContainer<NK>(codingPath: codingPath + [key]))
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        _ZeroUnkeyedContainer(codingPath: codingPath + [key])
    }
    func superDecoder() throws -> Decoder { _ZeroDecoder(codingPath: codingPath) }
    func superDecoder(forKey key: Key) throws -> Decoder { _ZeroDecoder(codingPath: codingPath + [key]) }
}

/// Always reports `isAtEnd = true` so any array decoded via `_ZeroDecoder` is empty.
final class _ZeroUnkeyedContainer: UnkeyedDecodingContainer {
    var codingPath: [CodingKey]
    var count: Int? { 0 }
    var currentIndex = 0
    var isAtEnd: Bool { true }
    init(codingPath: [CodingKey]) { self.codingPath = codingPath }

    private func end() throws -> Never {
        throw DecodingError.valueNotFound(Any.self,
            .init(codingPath: codingPath, debugDescription: "_ZeroUnkeyedContainer: already at end"))
    }
    func decodeNil()             throws -> Bool   { try end() }
    func decode(_ t: Bool.Type)   throws -> Bool   { try end() }
    func decode(_ t: String.Type) throws -> String  { try end() }
    func decode(_ t: Double.Type) throws -> Double  { try end() }
    func decode(_ t: Float.Type)  throws -> Float   { try end() }
    func decode(_ t: Int.Type)    throws -> Int     { try end() }
    func decode(_ t: Int8.Type)   throws -> Int8    { try end() }
    func decode(_ t: Int16.Type)  throws -> Int16   { try end() }
    func decode(_ t: Int32.Type)  throws -> Int32   { try end() }
    func decode(_ t: Int64.Type)  throws -> Int64   { try end() }
    func decode(_ t: UInt.Type)   throws -> UInt    { try end() }
    func decode(_ t: UInt8.Type)  throws -> UInt8   { try end() }
    func decode(_ t: UInt16.Type) throws -> UInt16  { try end() }
    func decode(_ t: UInt32.Type) throws -> UInt32  { try end() }
    func decode(_ t: UInt64.Type) throws -> UInt64  { try end() }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try end() }
    func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type) throws -> KeyedDecodingContainer<NK> { try end() }
    func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer { try end() }
    func superDecoder() throws -> Decoder { _ZeroDecoder(codingPath: codingPath) }
}

struct _ZeroSingleValueContainer: SingleValueDecodingContainer {
    var codingPath: [CodingKey]

    func decodeNil() -> Bool { false }
    func decode(_ t: Bool.Type)   throws -> Bool   { false }
    func decode(_ t: String.Type) throws -> String  { "" }
    func decode(_ t: Double.Type) throws -> Double  { 0 }
    func decode(_ t: Float.Type)  throws -> Float   { 0 }
    func decode(_ t: Int.Type)    throws -> Int     { 0 }
    func decode(_ t: Int8.Type)   throws -> Int8    { 0 }
    func decode(_ t: Int16.Type)  throws -> Int16   { 0 }
    func decode(_ t: Int32.Type)  throws -> Int32   { 0 }
    func decode(_ t: Int64.Type)  throws -> Int64   { 0 }
    func decode(_ t: UInt.Type)   throws -> UInt    { 0 }
    func decode(_ t: UInt8.Type)  throws -> UInt8   { 0 }
    func decode(_ t: UInt16.Type) throws -> UInt16  { 0 }
    func decode(_ t: UInt32.Type) throws -> UInt32  { 0 }
    func decode(_ t: UInt64.Type) throws -> UInt64  { 0 }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try _zeroValue(for: type, codingPath: codingPath)
    }
}

// MARK: - Helpers

/// Maps well-known Foundation types and arbitrary `Decodable` types to their `JSONSchema`.
func _inferSchema<T: Decodable>(for type: T.Type) -> JSONSchema {
    if type == Date.self { return .string(description: "ISO 8601 date string") }
    if type == UUID.self { return .string(description: "UUID") }
    if type == URL.self  { return .string(description: "URL") }
    if type == Data.self { return .string(description: "base64-encoded data") }
    let child = _SchemaRecorder()
    _ = try? T(from: child)
    return child.schema
}

/// Returns a safe dummy value of `T` by decoding through `_ZeroDecoder`,
/// with special-cased values for types whose `init(from:)` rejects zero/empty inputs.
func _zeroValue<T: Decodable>(for type: T.Type, codingPath: [CodingKey] = []) throws -> T {
    if type == UUID.self { return UUID(uuidString: "00000000-0000-0000-0000-000000000000")! as! T }
    if type == URL.self  { return URL(string: "https://example.com")! as! T }
    return try T(from: _ZeroDecoder(codingPath: codingPath))
}
