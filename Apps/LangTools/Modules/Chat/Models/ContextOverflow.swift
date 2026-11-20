//
//  ContextOverflow.swift
//

import Foundation

/// A provider's report that a request was longer than the model's context
/// window, with the counts it gave when it gave them.
///
/// Providers have no common error code for this, so it is recognized by the
/// wording OpenAI, Anthropic, Gemini, xAI and Mistral use (OpenAI-compatible
/// providers mostly repeat OpenAI's). Per-minute token limits and payload
/// size limits are different errors and are not matched.
public struct ContextOverflow: Equatable, Sendable {
    /// Input tokens the provider counted.
    public var requestedTokens: Int?
    /// The most input tokens the provider accepts for this model.
    public var maximumTokens: Int?

    public init(requestedTokens: Int? = nil, maximumTokens: Int? = nil) {
        self.requestedTokens = requestedTokens
        self.maximumTokens = maximumTokens
    }

    /// `nil` unless `error` says the request did not fit the context window.
    public init?(error: any Error) {
        if error is CancellationError { return nil }
        // Provider error bodies are often plain Codable structs, so their
        // text shows only in the reflected description.
        guard let overflow = Self.parse(error.localizedDescription + "\n" + String(describing: error)) else { return nil }
        self = overflow
    }

    static func parse(_ text: String) -> ContextOverflow? {
        let lowered = text.lowercased()
        guard markers.contains(where: lowered.contains) else { return nil }
        return ContextOverflow(
            requestedTokens: firstNumber(in: lowered, matching: requestedPatterns),
            maximumTokens: firstNumber(in: lowered, matching: maximumPatterns)
        )
    }

    private static let markers = [
        "context_length_exceeded",
        "maximum context length",
        "exceeds the context window",
        "prompt is too long",
        "exceeds the maximum number of tokens allowed",
        "maximum prompt length",
    ]

    private static let number = #"(\d[\d,]*)"#

    /// The first that matches wins, so the more specific come first. OpenAI's
    /// "requested N tokens (M in the messages, …)" counts the reply limit in
    /// N, so M is preferred.
    private static let requestedPatterns = [
        #"prompt is too long:\s*"# + number,
        #"\("# + number + #" in the messages"#,
        #"resulted in "# + number + #" tokens"#,
        #"requested (?:about )?"# + number + #" tokens"#,
        #"input token count \(?"# + number,
        #"request contains "# + number + #" tokens"#,
        #"prompt contains "# + number + #" tokens"#,
    ]

    private static let maximumPatterns = [
        #"maximum context length is "# + number,
        #"tokens\s*>\s*"# + number + #"\s*maximum"#,
        #"maximum number of tokens allowed \(?"# + number,
        #"maximum prompt length is "# + number,
        number + #" maximum context length"#,
    ]

    private static func firstNumber(in text: String, matching patterns: [String]) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: range),
                  let captured = Range(match.range(at: 1), in: text),
                  let value = Int(text[captured].replacingOccurrences(of: ",", with: ""))
            else { continue }
            return value
        }
        return nil
    }
}
