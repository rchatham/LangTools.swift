//
//  BuiltInToolsTests.swift
//  ToolKitTests
//

import XCTest
import OpenAI
import LangTools
@testable import ToolKit

final class CalculatorTests: XCTestCase {

    func testBasicArithmetic() throws {
        XCTAssertEqual(try Calculator.evaluate("2 + 3"), 5)
        XCTAssertEqual(try Calculator.evaluate("10 - 4"), 6)
        XCTAssertEqual(try Calculator.evaluate("6 * 7"), 42)
        XCTAssertEqual(try Calculator.evaluate("20 / 4"), 5)
    }

    func testOperatorPrecedence() throws {
        XCTAssertEqual(try Calculator.evaluate("2 + 3 * 4"), 14)
        XCTAssertEqual(try Calculator.evaluate("(2 + 3) * 4"), 20)
    }

    func testExponentiationRightAssociative() throws {
        XCTAssertEqual(try Calculator.evaluate("2 ^ 3"), 8)
        XCTAssertEqual(try Calculator.evaluate("2 ^ 3 ^ 2"), 512) // 2^(3^2) = 2^9
    }

    func testUnary() throws {
        XCTAssertEqual(try Calculator.evaluate("-5"), -5)
        XCTAssertEqual(try Calculator.evaluate("-(2 + 3)"), -5)
        XCTAssertEqual(try Calculator.evaluate("3 * -2"), -6)
    }

    func testModulo() throws {
        XCTAssertEqual(try Calculator.evaluate("10 % 3"), 1)
    }

    func testDecimals() throws {
        XCTAssertEqual(try Calculator.evaluate("2.5 * 4"), 10, accuracy: 1e-9)
        XCTAssertEqual(try Calculator.evaluate("0.1 + 0.2"), 0.3, accuracy: 1e-9)
    }

    func testScientificNotation() throws {
        XCTAssertEqual(try Calculator.evaluate("1e3"), 1000)
        XCTAssertEqual(try Calculator.evaluate("1.5e-2"), 0.015, accuracy: 1e-9)
    }

    func testFormatting() {
        XCTAssertEqual(Calculator.format(5), "5")
        XCTAssertEqual(Calculator.format(5.0), "5")
        XCTAssertEqual(Calculator.format(5.5), "5.5")
    }

    func testDivisionByZeroThrows() {
        XCTAssertThrowsError(try Calculator.evaluate("1 / 0"))
    }

    func testInvalidExpressionThrows() {
        XCTAssertThrowsError(try Calculator.evaluate("2 + "))
        XCTAssertThrowsError(try Calculator.evaluate("(2 + 3"))
        XCTAssertThrowsError(try Calculator.evaluate("abc"))
        XCTAssertThrowsError(try Calculator.evaluate("2 & 3"))
    }

    func testEmptyExpressionThrows() {
        XCTAssertThrowsError(try Calculator.evaluate(""))
    }
}

final class BuiltInToolConfigurationTests: XCTestCase {

    func testConfigurationsContainsExpectedTools() {
        let configs = BuiltInTools.configurations()
        let ids = Set(configs.map { $0.id })
        XCTAssertTrue(ids.contains("current_date_time"))
        XCTAssertTrue(ids.contains("calculate"))
    }

    func testConfigurationsAreNotAgents() {
        for config in BuiltInTools.configurations() {
            XCTAssertFalse(config.isAgent, "\(config.id) should not be an agent")
        }
    }

    func testCurrentDateTimeCallbackReturnsString() async throws {
        let args: [String: JSON] = ["time_zone": "America/Los_Angeles"]
        let result = try await BuiltInTools.currentDateTime.callback?(args)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("Current date and time:") == true)
    }

    func testCurrentDateTimeDefaultTimeZone() async throws {
        let result = try await BuiltInTools.currentDateTime.callback?([:])
        XCTAssertNotNil(result)
    }

    func testCurrentDateTimeInvalidTimeZoneThrows() async {
        let args: [String: JSON] = ["time_zone": "Mars/Olympus"]
        do {
            _ = try await BuiltInTools.currentDateTime.callback?(args)
            XCTFail("Expected invalid time zone to throw")
        } catch {
            // expected
        }
    }

    func testCalculateCallback() async throws {
        let args: [String: JSON] = ["expression": "(2 + 3) * 4"]
        let result = try await BuiltInTools.calculate.callback?(args)
        XCTAssertEqual(result, "20")
    }

    func testCalculateMissingExpressionThrows() async {
        do {
            _ = try await BuiltInTools.calculate.callback?([:])
            XCTFail("Expected missing expression to throw")
        } catch {
            // expected
        }
    }
}