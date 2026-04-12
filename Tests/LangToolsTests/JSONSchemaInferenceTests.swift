//
//  JSONSchemaInferenceTests.swift
//  LangToolsTests
//

import XCTest
@testable import LangTools

final class JSONSchemaInferenceTests: XCTestCase {

    // MARK: - Primitive properties

    func testPrimitiveProperties() {
        struct Primitive: Decodable {
            let name: String
            let score: Double
            let count: Int
            let ratio: Float
            let active: Bool
        }
        let schema = JSONSchema.infer(from: Primitive.self)
        XCTAssertEqual(schema.type, .object)
        XCTAssertEqual(schema.properties?["name"]?.type,   .string)
        XCTAssertEqual(schema.properties?["score"]?.type,  .number)
        XCTAssertEqual(schema.properties?["count"]?.type,  .integer)
        XCTAssertEqual(schema.properties?["ratio"]?.type,  .number)
        XCTAssertEqual(schema.properties?["active"]?.type, .boolean)
        XCTAssertEqual(Set(schema.required ?? []), ["name", "score", "count", "ratio", "active"])
    }

    // MARK: - Optional properties (not required)

    func testOptionalPropertiesAreNotRequired() {
        struct WithOptionals: Decodable {
            let required: String
            let optional: String?
            let optionalInt: Int?
        }
        let schema = JSONSchema.infer(from: WithOptionals.self)
        let req = Set(schema.required ?? [])
        XCTAssertTrue(req.contains("required"))
        XCTAssertFalse(req.contains("optional"))
        XCTAssertFalse(req.contains("optionalInt"))
        // Schema type is still inferred
        XCTAssertEqual(schema.properties?["optional"]?.type,    .string)
        XCTAssertEqual(schema.properties?["optionalInt"]?.type, .integer)
    }

    // MARK: - Integer variants

    func testIntegerVariants() {
        struct Ints: Decodable {
            let a: Int8; let b: Int16; let c: Int32; let d: Int64
            let e: UInt; let f: UInt8; let g: UInt16; let h: UInt32; let i: UInt64
        }
        let schema = JSONSchema.infer(from: Ints.self)
        for key in ["a","b","c","d","e","f","g","h","i"] {
            XCTAssertEqual(schema.properties?[key]?.type, .integer, "\(key) should be integer")
        }
    }

    // MARK: - Foundation types

    func testFoundationTypes() {
        struct FoundationFields: Decodable {
            let createdAt: Date
            let id: UUID
            let link: URL
            let blob: Data
        }
        let schema = JSONSchema.infer(from: FoundationFields.self)
        XCTAssertEqual(schema.properties?["createdAt"]?.type, .string)
        XCTAssertEqual(schema.properties?["id"]?.type,        .string)
        XCTAssertEqual(schema.properties?["link"]?.type,      .string)
        XCTAssertEqual(schema.properties?["blob"]?.type,      .string)
        // Descriptions should hint at the semantic meaning
        XCTAssertNotNil(schema.properties?["createdAt"]?.schemaDescription)
        XCTAssertNotNil(schema.properties?["id"]?.schemaDescription)
        XCTAssertNotNil(schema.properties?["link"]?.schemaDescription)
        XCTAssertNotNil(schema.properties?["blob"]?.schemaDescription)
    }

    // MARK: - Array properties

    func testArrayOfPrimitives() {
        struct WithArrays: Decodable {
            let tags: [String]
            let scores: [Double]
            let flags: [Bool]
        }
        let schema = JSONSchema.infer(from: WithArrays.self)
        XCTAssertEqual(schema.properties?["tags"]?.type,   .array)
        XCTAssertEqual(schema.properties?["scores"]?.type, .array)
        XCTAssertEqual(schema.properties?["flags"]?.type,  .array)
        XCTAssertEqual(schema.properties?["tags"]?.items?.type,   .string)
        XCTAssertEqual(schema.properties?["scores"]?.items?.type, .number)
        XCTAssertEqual(schema.properties?["flags"]?.items?.type,  .boolean)
    }

    func testArrayOfNestedObjects() {
        struct Item: Decodable { let value: String }
        struct Container: Decodable { let items: [Item] }
        let schema = JSONSchema.infer(from: Container.self)
        XCTAssertEqual(schema.properties?["items"]?.type,        .array)
        XCTAssertEqual(schema.properties?["items"]?.items?.type, .object)
        XCTAssertEqual(schema.properties?["items"]?.items?.properties?["value"]?.type, .string)
    }

    // MARK: - Nested objects

    func testNestedObject() {
        struct Address: Decodable {
            let street: String
            let city: String
        }
        struct Person: Decodable {
            let name: String
            let address: Address
        }
        let schema = JSONSchema.infer(from: Person.self)
        XCTAssertEqual(schema.properties?["name"]?.type,    .string)
        XCTAssertEqual(schema.properties?["address"]?.type, .object)
        XCTAssertEqual(schema.properties?["address"]?.properties?["street"]?.type, .string)
        XCTAssertEqual(schema.properties?["address"]?.properties?["city"]?.type,   .string)
    }

    func testDeeplyNestedObjects() {
        struct C: Decodable { let val: Int }
        struct B: Decodable { let c: C }
        struct A: Decodable { let b: B }
        let schema = JSONSchema.infer(from: A.self)
        XCTAssertEqual(schema.properties?["b"]?.type,                         .object)
        XCTAssertEqual(schema.properties?["b"]?.properties?["c"]?.type,       .object)
        XCTAssertEqual(schema.properties?["b"]?.properties?["c"]?.properties?["val"]?.type, .integer)
    }

    // MARK: - String enum (raw-value)

    func testStringEnumProperty() {
        enum Status: String, Codable { case active, inactive }
        struct Item: Decodable { let status: Status }
        let schema = JSONSchema.infer(from: Item.self)
        // Enums with String raw value decode via singleValueContainer → .string
        XCTAssertEqual(schema.properties?["status"]?.type, .string)
    }

    // MARK: - additionalProperties = false

    func testAdditionalPropertiesFalse() {
        struct Simple: Decodable { let x: Int }
        let schema = JSONSchema.infer(from: Simple.self)
        XCTAssertEqual(schema.additionalProperties, .bool(false))
    }

    // MARK: - Empty struct

    func testEmptyStructProducesEmptyObject() {
        struct Empty: Decodable {}
        let schema = JSONSchema.infer(from: Empty.self)
        XCTAssertEqual(schema.type, .object)
        XCTAssertTrue(schema.properties?.isEmpty ?? true)
        XCTAssertNil(schema.required)
    }

    // MARK: - CodingKeys renaming

    func testCustomCodingKeys() {
        struct Renamed: Decodable {
            let firstName: String
            enum CodingKeys: String, CodingKey { case firstName = "first_name" }
        }
        let schema = JSONSchema.infer(from: Renamed.self)
        // The JSON key is "first_name", not "firstName"
        XCTAssertNotNil(schema.properties?["first_name"])
        XCTAssertNil(schema.properties?["firstName"])
    }
}
