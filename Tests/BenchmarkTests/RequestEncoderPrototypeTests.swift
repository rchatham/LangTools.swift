import XCTest
import Foundation
@testable import OpenAI

/// Test-only candidate: check optional presence before entering the keyed container.
struct OpenAIRequestEncoderPrototype: Encodable {
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
        if let value = request.temperature { try container.encode(value, forKey: .temperature) }
        if let value = request.top_p { try container.encode(value, forKey: .top_p) }
        if let value = request.n { try container.encode(value, forKey: .n) }
        if let value = request.stream { try container.encode(value, forKey: .stream) }
        if let value = request.stream_options { try container.encode(value, forKey: .stream_options) }
        if let value = request.stop { try container.encode(value, forKey: .stop) }
        if let value = request.max_tokens { try container.encode(value, forKey: .max_tokens) }
        if let value = request.max_completion_tokens { try container.encode(value, forKey: .max_completion_tokens) }
        if let value = request.presence_penalty { try container.encode(value, forKey: .presence_penalty) }
        if let value = request.frequency_penalty { try container.encode(value, forKey: .frequency_penalty) }
        if let value = request.logit_bias { try container.encode(value, forKey: .logit_bias) }
        if let value = request.logprobs { try container.encode(value, forKey: .logprobs) }
        if let value = request.top_logprobs { try container.encode(value, forKey: .top_logprobs) }
        if let value = request.user { try container.encode(value, forKey: .user) }
        if let value = request.response_format { try container.encode(value, forKey: .response_format) }
        if let value = request.seed { try container.encode(value, forKey: .seed) }
        if let value = request.tools { try container.encode(value, forKey: .tools) }
        if let value = request.tool_choice { try container.encode(value, forKey: .tool_choice) }
        if let value = request.parallel_tool_calls { try container.encode(value, forKey: .parallel_tool_calls) }
        if let value = request.service_tier { try container.encode(value, forKey: .service_tier) }
        if let value = request.store { try container.encode(value, forKey: .store) }
        if let value = request.prediction { try container.encode(value, forKey: .prediction) }
        if let value = request.modalities { try container.encode(value, forKey: .modalities) }
        if let value = request.audio { try container.encode(value, forKey: .audio) }
        if let value = request.reasoning_effort { try container.encode(value, forKey: .reasoning_effort) }
        if let value = request.metadata { try container.encode(value, forKey: .metadata) }
    }
}

extension PairedEncodeBenchmarkTests {
    func testRequestEncoderCurrentVsLegacy() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LANGTOOLS_RUN_PAIRED_BENCHMARKS"] == "1")
        for count in [1, 50] {
            let messages: [OpenAI.Message] = (0..<count).map {
                .init(role: $0.isMultiple(of: 2) ? .user : .assistant,
                      content: count == 1 ? "What's the weather in SF?" : "Message \($0) with realistic content for benchmarking.")
            }
            for stream: Bool? in [nil, false] {
                let request = OpenAI.ChatCompletionRequest(model: .gpt4o, messages: messages, stream: stream)
                try compare(LegacyOpenAIRequestEncoder(request), request,
                            key: "OpenAI.\(count).requestEncoder.currentOverLegacy.stream\(stream == nil ? "Omitted" : "False")", iterations: count == 1 ? 10_000 : 1_000)
                try compare(OpenAIRequestEncoderPrototype(request: request), request,
                            key: "OpenAI.\(count).requestEncoder.prototypeCalibration.stream\(stream == nil ? "Omitted" : "False")", iterations: count == 1 ? 10_000 : 1_000)
            }
        }
        let rich = try RequestEncoderPrototypeTests.populatedRequest()
        try compare(LegacyOpenAIRequestEncoder(rich), rich, key: "OpenAI.rich.requestEncoder.currentOverLegacy", iterations: 2_000)
    }
}

final class RequestEncoderPrototypeTests: XCTestCase {
    static func populatedRequest() throws -> OpenAI.ChatCompletionRequest {
        let json = #"{"model":"gpt-4o","messages":[{"role":"user","content":"héllo 🌍"}],"temperature":0.5,"top_p":0.9,"n":2,"stream":false,"stream_options":{"include_usage":true},"stop":["END"],"max_tokens":64,"max_completion_tokens":64,"presence_penalty":0.1,"frequency_penalty":0.2,"logit_bias":{"1":0.5},"logprobs":true,"top_logprobs":2,"user":"user-1","response_format":{"type":"json_schema","json_schema":{"name":"answer","strict":true,"schema":{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}}},"seed":42,"tools":[{"type":"function","function":{"name":"weather","description":"weather","parameters":{"type":"object","properties":{}}}}],"tool_choice":{"type":"function","function":{"name":"weather"}},"parallel_tool_calls":false,"service_tier":"default","store":false,"prediction":{"type":"content","content":"hello"},"modalities":["text","audio"],"audio":{"voice":"alloy","format":"wav"},"reasoning_effort":"low","metadata":{"key":"value"}}"#
        return try JSONDecoder().decode(OpenAI.ChatCompletionRequest.self, from: Data(json.utf8))
    }

    func testPrototypeWireParity() throws {
        let fixtures = [OpenAI.ChatCompletionRequest(model: .gpt4o, messages: [OpenAI.Message]()), try Self.populatedRequest()]
        for request in fixtures {
            for strategy: JSONEncoder.KeyEncodingStrategy in [.useDefaultKeys, .convertToSnakeCase] {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.keyEncodingStrategy = strategy
                XCTAssertEqual(try encoder.encode(request), try encoder.encode(OpenAIRequestEncoderPrototype(request: request)))
                XCTAssertEqual(try encoder.encode(request), try encoder.encode(LegacyOpenAIRequestEncoder(request)))
            }
        }
    }
}
