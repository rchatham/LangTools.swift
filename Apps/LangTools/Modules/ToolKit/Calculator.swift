//
//  Calculator.swift
//  ToolKit
//
//  Created by Reid Chatham on 9/14/25.
//

import Foundation

/// A safe, dependency-free arithmetic evaluator for the `calculate` tool.
///
/// Supports addition, subtraction, multiplication, division, modulo, exponentiation,
/// parentheses, unary plus/minus, and decimal numbers. No `eval` or `NSExpression`
/// is used, so arbitrary code cannot run.
public enum Calculator {
    /// Evaluates an arithmetic expression and returns the numeric result.
    /// - Throws: `ToolError.invalidExpression` for malformed input or math errors.
    public static func evaluate(_ expression: String) throws -> Double {
        var tokenizer = Tokenizer(expression: expression)
        let tokens = try tokenizer.tokenize()
        var parser = Parser(tokens: tokens)
        let result = try parser.parseExpression()
        guard parser.consume(Token.end) else {
            throw ToolError.invalidExpression(expression)
        }
        guard result.isFinite else {
            throw ToolError.invalidExpression(expression)
        }
        return result
    }

    /// Formats a numeric result for display, trimming insignificant trailing zeros.
    public static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}

// MARK: - Tokens

private enum Token: Equatable {
    case number(Double)
    case plus, minus, star, slash, percent, caret
    case openParen, closeParen
    case end
}

private struct Tokenizer {
    let expression: String
    private let characters: [Character]
    private var index: Int = 0

    init(expression: String) {
        self.expression = expression
        self.characters = Array(expression)
    }

    mutating func tokenize() throws -> [Token] {
        var tokens: [Token] = []
        while index < characters.count {
            let char = characters[index]
            switch char {
            case " ", "\t", "\n", "\r":
                index += 1
            case "+":
                tokens.append(.plus); index += 1
            case "-":
                tokens.append(.minus); index += 1
            case "*":
                tokens.append(.star); index += 1
            case "/":
                tokens.append(.slash); index += 1
            case "%":
                tokens.append(.percent); index += 1
            case "^":
                tokens.append(.caret); index += 1
            case "(":
                tokens.append(.openParen); index += 1
            case ")":
                tokens.append(.closeParen); index += 1
            case "0"..."9", ".":
                tokens.append(try readNumber())
            default:
                throw ToolError.invalidExpression(expression)
            }
        }
        tokens.append(.end)
        return tokens
    }

    private mutating func readNumber() throws -> Token {
        let start = index
        var hasDigit = false
        var hasDot = false
        while index < characters.count {
            let char = characters[index]
            if char.isNumber {
                hasDigit = true
                index += 1
            } else if char == "." {
                if hasDot {
                    throw ToolError.invalidExpression(expression)
                }
                hasDot = true
                index += 1
            } else if char.lowercased() == "e" {
                // Scientific notation: 1e3, 1.5e-2
                index += 1
                if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                    index += 1
                }
                guard index < characters.count, characters[index].isNumber else {
                    throw ToolError.invalidExpression(expression)
                }
                while index < characters.count, characters[index].isNumber { index += 1 }
                break
            } else {
                break
            }
        }
        guard hasDigit else { throw ToolError.invalidExpression(expression) }
        guard let value = Double(String(characters[start..<index])) else {
            throw ToolError.invalidExpression(expression)
        }
        return .number(value)
    }
}

// MARK: - Parser (recursive descent)

private struct Parser {
    private let tokens: [Token]
    private var index: Int = 0

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    private var current: Token {
        index < tokens.count ? tokens[index] : .end
    }

    @discardableResult
    mutating func consume(_ token: Token) -> Bool {
        guard current == token else { return false }
        index += 1
        return true
    }

    // expression = term (("+" | "-") term)*
    mutating func parseExpression() throws -> Double {
        var result = try parseTerm()
        while true {
            if consume(.plus) {
                result = try result + parseTerm()
            } else if consume(.minus) {
                result = try result - parseTerm()
            } else {
                return result
            }
        }
    }

    // term = factor (("*" | "/" | "%") factor)*
    private mutating func parseTerm() throws -> Double {
        var result = try parseFactor()
        while true {
            if consume(.star) {
                result = try result * parseFactor()
            } else if consume(.slash) {
                let rhs = try parseFactor()
                guard rhs != 0 else { throw ToolError.invalidExpression("/ by zero") }
                result = result / rhs
            } else if consume(.percent) {
                let rhs = try parseFactor()
                guard rhs != 0 else { throw ToolError.invalidExpression("% by zero") }
                result = result.truncatingRemainder(dividingBy: rhs)
            } else {
                return result
            }
        }
    }

    // factor = unary ("^" factor)?   (right associative)
    private mutating func parseFactor() throws -> Double {
        let base = try parseUnary()
        if consume(.caret) {
            let exponent = try parseFactor()
            let value = pow(base, exponent)
            guard value.isFinite else { throw ToolError.invalidExpression("overflow") }
            return value
        }
        return base
    }

    // unary = ("+" | "-")? primary
    private mutating func parseUnary() throws -> Double {
        if consume(.plus) { return try parseUnary() }
        if consume(.minus) { return try -parseUnary() }
        return try parsePrimary()
    }

    // primary = number | "(" expression ")"
    private mutating func parsePrimary() throws -> Double {
        switch current {
        case .number(let value):
            index += 1
            return value
        case .openParen:
            index += 1
            let value = try parseExpression()
            guard consume(.closeParen) else { throw ToolError.invalidExpression("missing )") }
            return value
        default:
            throw ToolError.invalidExpression("unexpected token")
        }
    }
}