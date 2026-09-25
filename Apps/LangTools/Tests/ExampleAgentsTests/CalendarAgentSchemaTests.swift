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

    // MARK: - Decode round trips

    func testResponseDecodesStrictPayloadWithNullOptionals() throws {
        let json = """
        {"events":[{"title":"Standup","startDate":"2026-06-01T09:00:00Z","endDate":"2026-06-01T09:30:00Z","location":null,"notes":null,"isAllDay":false,"calendarName":null,"eventIdentifier":null}],"message":null}
        """

        let response = try JSONDecoder().decode(CalendarAgentResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.events.count, 1)
        XCTAssertEqual(response.events[0].title, "Standup")
        XCTAssertNil(response.events[0].location)
        XCTAssertNil(response.events[0].eventIdentifier)
        XCTAssertNil(response.message)
    }

    func testResponseDecodesFullyPopulatedPayload() throws {
        let json = """
        {"events":[{"title":"Launch","startDate":"2026-06-02T00:00:00Z","endDate":"2026-06-02T01:00:00Z","location":"Stage","notes":"Bring demos","isAllDay":true,"calendarName":"Work","eventIdentifier":"event-1"}],"message":"One event"}
        """

        let response = try JSONDecoder().decode(CalendarAgentResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.events.count, 1)
        XCTAssertEqual(response.events[0].location, "Stage")
        XCTAssertEqual(response.events[0].calendarName, "Work")
        XCTAssertEqual(response.message, "One event")
    }

    func testResponseDecodesPreviouslyValidLoosePayloads() throws {
        // Payloads emitted before the strict schema (missing optional keys
        // entirely) still decode: the strict schema constrains what providers
        // must send, not what the decoder accepts.
        let json = """
        {"events":[{"title":"Standup","startDate":"2026-06-01T09:00:00Z","endDate":"2026-06-01T09:30:00Z","isAllDay":false}]}
        """

        let response = try JSONDecoder().decode(CalendarAgentResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.events.count, 1)
        XCTAssertNil(response.events[0].location)
        XCTAssertNil(response.message)
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
