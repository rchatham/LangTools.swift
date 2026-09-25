//
//  BuiltInTools.swift
//  ToolKit
//
//  Created by Reid Chatham on 9/14/25.
//

import Foundation
import LangTools
import OpenAI

/// Factory for non-agent tools the chat LLM can call directly.
///
/// These tools are pure and dependency-free so they can be registered by any host
/// app (LangTools_Example or the parent App) without credentials or platform APIs.
public enum BuiltInTools {
    /// All built-in, non-agent tool configurations.
    public static func configurations() -> [ToolConfiguration] {
        [
            currentDateTime,
            calculate
        ]
    }

    /// Returns the current date and time, optionally in a named time zone.
    public static let currentDateTime: ToolConfiguration = {
        let schema = OpenAI.Tool.FunctionSchema.Parameters(
            properties: [
                "time_zone": .init(
                    type: "string",
                    description: "An IANA time zone identifier such as \"America/Los_Angeles\". Defaults to the device's current time zone."
                )
            ],
            required: []
        )
        return ToolConfiguration(
            id: "current_date_time",
            displayName: "Date & Time",
            description: "Get the current date and time, optionally for a specific time zone.",
            iconName: "clock",
            isAgent: false,
            callback: { args in
                let timeZone: TimeZone
                if let tzID = args["time_zone"]?.stringValue, !tzID.isEmpty {
                    guard let tz = TimeZone(identifier: tzID) else {
                        throw ToolError.invalidTimeZone(tzID)
                    }
                    timeZone = tz
                } else {
                    timeZone = .current
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
                formatter.timeZone = timeZone
                formatter.locale = Locale(identifier: "en_US_POSIX")
                return "Current date and time: \(formatter.string(from: Date()))"
            },
            toolSchema: schema,
            requiredParameters: []
        )
    }()

    /// Evaluates a numeric arithmetic expression and returns the result.
    public static let calculate: ToolConfiguration = {
        let schema = OpenAI.Tool.FunctionSchema.Parameters(
            properties: [
                "expression": .init(
                    type: "string",
                    description: "An arithmetic expression using +, -, *, /, %, ^ and parentheses, e.g. \"(2 + 3) * 4\"."
                )
            ],
            required: ["expression"]
        )
        return ToolConfiguration(
            id: "calculate",
            displayName: "Calculator",
            description: "Evaluate a numeric arithmetic expression.",
            iconName: "plus.forwardslash.minus",
            isAgent: false,
            callback: { args in
                guard let expression = args["expression"]?.stringValue, !expression.isEmpty else {
                    throw ToolError.missingExpression
                }
                let value = try Calculator.evaluate(expression)
                return Calculator.format(value)
            },
            toolSchema: schema,
            requiredParameters: ["expression"]
        )
    }()
}

/// Errors thrown by built-in tools.
public enum ToolError: LocalizedError {
    case invalidTimeZone(String)
    case missingExpression
    case invalidExpression(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTimeZone(let id):
            return "Unknown time zone: \(id)"
        case .missingExpression:
            return "Missing required \"expression\" parameter."
        case .invalidExpression(let expr):
            return "Could not evaluate expression: \(expr)"
        }
    }
}