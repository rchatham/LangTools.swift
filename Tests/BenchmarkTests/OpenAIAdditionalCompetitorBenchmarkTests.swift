import XCTest

#if canImport(MacPawOpenAI)
import MacPawOpenAI
#endif

#if canImport(OpenAISwift)
@testable import OpenAISwift
#endif

final class OpenAIAdditionalCompetitorBenchmarkTests: XCTestCase {
    static let chatCompletionJSON = """
    {"id":"chatcmpl-bench","object":"chat.completion","created":1700000000,"model":"gpt-4o-2024-08-06","system_fingerprint":"fp_bench","choices":[{"index":0,"message":{"role":"assistant","content":"The weather in San Francisco is currently 72°F with partly cloudy skies. The humidity is at 65% and winds are coming from the west at 12 mph."},"finish_reason":"stop"}],"usage":{"prompt_tokens":25,"completion_tokens":60,"total_tokens":85}}
    """.data(using: .utf8)!

    static let toolCallJSON = """
    {"id":"chatcmpl-bench-tool","object":"chat.completion","created":1700000000,"model":"gpt-4o-2024-08-06","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\\"location\\":\\"San Francisco\\",\\"unit\\":\\"fahrenheit\\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":30,"total_tokens":80}}
    """.data(using: .utf8)!

    static let streamChunkJSON = """
    {"id":"chatcmpl-bench","object":"chat.completion.chunk","created":1700000000,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":"Hello "},"finish_reason":null}]}
    """.data(using: .utf8)!

    #if canImport(MacPawOpenAI)
    func testMacPawOpenAI_DecodeResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(MacPawOpenAI.ChatResult.self, from: Self.chatCompletionJSON)
            }
        }
    }

    func testMacPawOpenAI_DecodeToolCallResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(MacPawOpenAI.ChatResult.self, from: Self.toolCallJSON)
            }
        }
    }

    func testMacPawOpenAI_DecodeStreamChunk() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<1000 {
                _ = try! decoder.decode(MacPawOpenAI.ChatStreamResult.self, from: Self.streamChunkJSON)
            }
        }
    }

    func testMacPawOpenAI_EncodeRequest() {
        let query = MacPawOpenAI.ChatQuery(
            messages: [.user(.init(content: .string("What's the weather in SF?")))],
            model: MacPawOpenAI.Model.gpt4_o
        )
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<500 {
                _ = try! encoder.encode(query)
            }
        }
    }

    func testMacPawOpenAI_EncodeRequest_LargeConversation() {
        let messages: [MacPawOpenAI.ChatQuery.ChatCompletionMessageParam] = (0..<50).map { i in
            let content = "Message \(i) with realistic content for benchmarking."
            if i % 2 == 0 {
                return .user(.init(content: .string(content)))
            } else {
                return .assistant(.init(content: .textContent(content)))
            }
        }
        let query = MacPawOpenAI.ChatQuery(messages: messages, model: MacPawOpenAI.Model.gpt4_o)
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(query)
            }
        }
    }
    #endif

    #if canImport(OpenAISwift)
    func testOpenAISwift_DecodeResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(OpenAI<MessageResult>.self, from: Self.chatCompletionJSON)
            }
        }
    }

    func testOpenAISwift_DecodeToolCallResponse() {
        let decoder = JSONDecoder()
        measure {
            for _ in 0..<500 {
                _ = try! decoder.decode(OpenAI<MessageResult>.self, from: Self.toolCallJSON)
            }
        }
    }

    func testOpenAISwift_EncodeRequest() {
        let conversation = ChatConversation(
            user: Optional<String>.none,
            messages: [ChatMessage(role: .user, content: "What's the weather in SF?")],
            model: OpenAIModelType.other("gpt-4o").modelName,
            temperature: Optional<Double>.none,
            topProbabilityMass: Optional<Double>.none,
            choices: Optional<Int>.none,
            stop: Optional<[String]>.none,
            maxTokens: Optional<Int>.none,
            presencePenalty: Optional<Double>.none,
            frequencyPenalty: Optional<Double>.none,
            logitBias: Optional<[Int: Double]>.none,
            stream: false
        )
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<500 {
                _ = try! encoder.encode(conversation)
            }
        }
    }

    func testOpenAISwift_EncodeRequest_LargeConversation() {
        let messages: [ChatMessage] = (0..<50).map { i in
            .init(role: i % 2 == 0 ? .user : .assistant,
                  content: "Message \(i) with realistic content for benchmarking.")
        }
        let conversation = ChatConversation(
            user: Optional<String>.none,
            messages: messages,
            model: OpenAIModelType.other("gpt-4o").modelName,
            temperature: Optional<Double>.none,
            topProbabilityMass: Optional<Double>.none,
            choices: Optional<Int>.none,
            stop: Optional<[String]>.none,
            maxTokens: Optional<Int>.none,
            presencePenalty: Optional<Double>.none,
            frequencyPenalty: Optional<Double>.none,
            logitBias: Optional<[Int: Double]>.none,
            stream: false
        )
        let encoder = JSONEncoder()
        measure {
            for _ in 0..<100 {
                _ = try! encoder.encode(conversation)
            }
        }
    }
    #endif
}
