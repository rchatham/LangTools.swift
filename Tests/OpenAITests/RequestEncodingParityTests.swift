import XCTest
import Foundation
@testable import OpenAI

final class RequestEncodingParityTests: XCTestCase {
    /// Matches the former synthesized encoder's encodeIfPresent calls and key names.
    private struct Legacy: Encodable {
        let request: OpenAI.ChatCompletionRequest
        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, top_p, n, stream, stream_options, stop
            case max_tokens, max_completion_tokens, presence_penalty, frequency_penalty
            case logit_bias, logprobs, top_logprobs, user, response_format, seed, tools
            case tool_choice, parallel_tool_calls, service_tier, store, prediction
            case modalities, audio, reasoning_effort, metadata
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(request.model, forKey: .model)
            try container.encode(request.messages, forKey: .messages)
            try container.encodeIfPresent(request.temperature, forKey: .temperature)
            try container.encodeIfPresent(request.top_p, forKey: .top_p)
            try container.encodeIfPresent(request.n, forKey: .n)
            try container.encodeIfPresent(request.stream, forKey: .stream)
            try container.encodeIfPresent(request.stream_options, forKey: .stream_options)
            try container.encodeIfPresent(request.stop, forKey: .stop)
            try container.encodeIfPresent(request.max_tokens, forKey: .max_tokens)
            try container.encodeIfPresent(request.max_completion_tokens, forKey: .max_completion_tokens)
            try container.encodeIfPresent(request.presence_penalty, forKey: .presence_penalty)
            try container.encodeIfPresent(request.frequency_penalty, forKey: .frequency_penalty)
            try container.encodeIfPresent(request.logit_bias, forKey: .logit_bias)
            try container.encodeIfPresent(request.logprobs, forKey: .logprobs)
            try container.encodeIfPresent(request.top_logprobs, forKey: .top_logprobs)
            try container.encodeIfPresent(request.user, forKey: .user)
            try container.encodeIfPresent(request.response_format, forKey: .response_format)
            try container.encodeIfPresent(request.seed, forKey: .seed)
            try container.encodeIfPresent(request.tools, forKey: .tools)
            try container.encodeIfPresent(request.tool_choice, forKey: .tool_choice)
            try container.encodeIfPresent(request.parallel_tool_calls, forKey: .parallel_tool_calls)
            try container.encodeIfPresent(request.service_tier, forKey: .service_tier)
            try container.encodeIfPresent(request.store, forKey: .store)
            try container.encodeIfPresent(request.prediction, forKey: .prediction)
            try container.encodeIfPresent(request.modalities, forKey: .modalities)
            try container.encodeIfPresent(request.audio, forKey: .audio)
            try container.encodeIfPresent(request.reasoning_effort, forKey: .reasoning_effort)
            try container.encodeIfPresent(request.metadata, forKey: .metadata)
        }
    }

    private static let populatedJSON = #"{"model":"gpt-4o","messages":[{"role":"user","content":"héllo 🌍"}],"temperature":0.5,"top_p":0.9,"n":2,"stream":false,"stream_options":{"include_usage":true},"stop":["END"],"max_tokens":64,"max_completion_tokens":64,"presence_penalty":0.1,"frequency_penalty":0.2,"logit_bias":{"1":0.5},"logprobs":true,"top_logprobs":2,"user":"user-1","response_format":{"type":"json_schema","json_schema":{"name":"answer","strict":true,"schema":{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}}},"seed":42,"tools":[{"type":"function","function":{"name":"weather","description":"weather","parameters":{"type":"object","properties":{}}}}],"tool_choice":{"type":"function","function":{"name":"weather"}},"parallel_tool_calls":false,"service_tier":"default","store":false,"prediction":{"type":"content","content":"hello"},"modalities":["text","audio"],"audio":{"voice":"alloy","format":"wav"},"reasoning_effort":"low","metadata":{"key":"value"}}"#

    private struct PrefixedKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private func assertParity(_ request: OpenAI.ChatCompletionRequest, file: StaticString = #filePath, line: UInt = #line) throws {
        let strategies: [JSONEncoder.KeyEncodingStrategy] = [
            .useDefaultKeys, .convertToSnakeCase,
            .custom { PrefixedKey(stringValue: "wire_" + $0.last!.stringValue)! }
        ]
        for strategy in strategies {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.keyEncodingStrategy = strategy
            XCTAssertEqual(try encoder.encode(request), try encoder.encode(Legacy(request: request)), file: file, line: line)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(request)
        let decoded = try JSONDecoder().decode(OpenAI.ChatCompletionRequest.self, from: encoded)
        XCTAssertEqual(encoded, try encoder.encode(decoded), file: file, line: line)
    }

    func testAllOptionalFieldsAndIndividualPresence() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.populatedJSON.utf8)) as? [String: Any])
        let required: [String: Any] = ["model": object["model"]!, "messages": object["messages"]!]
        let decoder = JSONDecoder()
        let rich = try decoder.decode(OpenAI.ChatCompletionRequest.self, from: Data(Self.populatedJSON.utf8))
        try assertParity(rich)
        // Confirm every supplied key actually survived decoding; don't compare two encoders of lost data.
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rich)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(encodedObject.keys))
        for (key, value) in object where key != "model" && key != "messages" {
            var individual = required
            individual[key] = value
            try assertParity(decoder.decode(OpenAI.ChatCompletionRequest.self, from: JSONSerialization.data(withJSONObject: individual)))
            var absent = object
            absent.removeValue(forKey: key)
            try assertParity(decoder.decode(OpenAI.ChatCompletionRequest.self, from: JSONSerialization.data(withJSONObject: absent)))
        }
    }

    func testEmptyFalseZeroAndAlternateEnums() throws {
        let variants = [
            #"{"model":"gpt-4o","messages":[],"temperature":0,"n":0,"stream":false,"stop":"END","tools":[],"metadata":{},"logit_bias":{},"modalities":[],"store":false,"response_format":{"type":"text"},"tool_choice":"none"}"#,
            #"{"model":"gpt-4o","messages":[],"stream":true,"stop":[],"response_format":{"type":"json_object"},"tool_choice":"required"}"#,
            #"{"model":"gpt-4o","messages":[],"tool_choice":"auto"}"#,
            #"{"model":"gpt-4o","messages":[]}"#
        ]
        for json in variants {
            try assertParity(JSONDecoder().decode(OpenAI.ChatCompletionRequest.self, from: Data(json.utf8)))
        }
    }

    func testCallbacksStayOmittedAndDecodingRestoresNil() throws {
        let request = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: [OpenAI.Message](), choose: { _ in 7 }, toolEventHandler: { _ in XCTFail("Must not execute callback during encoding") })
        try assertParity(request)
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["model", "messages"])
        XCTAssertEqual(request.choose(from: []), 7)
        let decoded = try JSONDecoder().decode(OpenAI.ChatCompletionRequest.self, from: data)
        XCTAssertNil(decoded._choose)
        XCTAssertNil(decoded.toolEventHandler)
    }

    func testNonconformingFloatErrorAndConversionMatch() throws {
        let request = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: [OpenAI.Message](), temperature: .nan)
        let encoder = JSONEncoder()
        XCTAssertThrowsError(try encoder.encode(request))
        XCTAssertThrowsError(try encoder.encode(Legacy(request: request)))
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(request), try encoder.encode(Legacy(request: request)))
    }
}
