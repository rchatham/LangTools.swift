//
//  CalendarAgentSchemaTests.swift
//  ExampleAgentsTests
//

import LangTools
import XCTest
@testable import ExampleAgents

final class CalendarAgentSchemaTests: XCTestCase {
    func testResponseSchemaIsStrictAndRequiresNullableMessage() throws {
        let schema = CalendarAgentResponse.jsonSchema

        XCTAssertEqual(schema.type, .object)
        XCTAssertEqual(Set(try XCTUnwrap(schema.required)), ["events", "message"])
        XCTAssertEqual(schema.additionalProperties, .bool(false))

        let properties = try XCTUnwrap(schema.properties)
        XCTAssertEqual(Set(properties.keys), ["events", "message"])
        XCTAssertEqual(properties["events"]?.type, .array)
        assertNullableString(try XCTUnwrap(properties["message"]))
    }

    func testEventSchemaIsStrictAndRequiresEveryProperty() throws {
        let schema = CalendarEventData.jsonSchema
        let expectedProperties: Set<String> = [
            "title",
            "startDate",
            "endDate",
            "location",
            "notes",
            "isAllDay",
            "calendarName",
            "eventIdentifier",
        ]

        XCTAssertEqual(schema.type, .object)
        XCTAssertEqual(Set(try XCTUnwrap(schema.required)), expectedProperties)
        XCTAssertEqual(schema.additionalProperties, .bool(false))

        let properties = try XCTUnwrap(schema.properties)
        XCTAssertEqual(Set(properties.keys), expectedProperties)
        XCTAssertEqual(properties["title"]?.type, .string)
        XCTAssertEqual(properties["startDate"]?.type, .string)
        XCTAssertEqual(properties["endDate"]?.type, .string)
        XCTAssertEqual(properties["isAllDay"]?.type, .boolean)
        for name in ["location", "notes", "calendarName", "eventIdentifier"] {
            assertNullableString(try XCTUnwrap(properties[name]), file: #filePath, line: #line)
        }
    }

    func testNestedEventSchemaRemainsStrictInResponseArray() throws {
        let eventSchema = try XCTUnwrap(
            CalendarAgentResponse.jsonSchema.properties?["events"]?.items
        )

        XCTAssertEqual(eventSchema.additionalProperties, .bool(false))
        XCTAssertEqual(
            Set(try XCTUnwrap(eventSchema.required)),
            Set(try XCTUnwrap(CalendarEventData.jsonSchema.required))
        )
    }

    private func assertNullableString(
        _ schema: JSONSchema,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(schema.type, file: file, line: line)
        XCTAssertEqual(Set(schema.anyOf?.compactMap(\.type) ?? []), [.string, .null], file: file, line: line)
    }
}
