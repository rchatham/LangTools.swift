//
//  PerformanceTestHelpers.swift
//  LangTools
//
//  Performance test helpers for generating large test payloads.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenAI
import Anthropic

public enum PerformanceFixtures {

    // MARK: - OpenAI Fixtures

    public static func openAIChatCompletionResponseJSON(choiceCount: Int = 1) -> Data {
        let choices = (0..<choiceCount).map { i in
            """
            {
                "index": \(i),
                "message": {
                    "role": "assistant",
                    "content": "This is a test response with some meaningful content for performance testing. The quick brown fox jumps over the lazy dog. Lorem ipsum dolor sit amet, consectetur adipiscing elit."
                },
                "logprobs": {
                    "content": [
                        {"token": "This", "logprob": -0.5, "bytes": [84,104,105,115], "top_logprobs": [{"token": "The", "logprob": -1.0, "bytes": [84,104,101]}]},
                        {"token": " is", "logprob": -0.3, "bytes": [32,105,115], "top_logprobs": [{"token": " was", "logprob": -1.5, "bytes": [32,119,97,115]}]}
                    ]
                },
                "finish_reason": "stop"
            }
            """
        }.joined(separator: ",\n")

        return """
        {
            "id": "chatcmpl-perf-test-\(choiceCount)",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "gpt-4o-2024-08-06",
            "system_fingerprint": "fp_perf_test",
            "choices": [\(choices)],
            "usage": {
                "prompt_tokens": 50,
                "completion_tokens": \(100 * choiceCount),
                "total_tokens": \(50 + 100 * choiceCount),
                "completion_tokens_details": {
                    "reasoning_tokens": 0,
                    "accepted_prediction_tokens": 0,
                    "rejected_prediction_tokens": 0
                },
                "prompt_tokens_details": {
                    "audio_tokens": 0,
                    "cached_tokens": 0
                }
            },
            "service_tier": "default"
        }
        """.data(using: .utf8)!
    }

    public static func openAIStreamChunksData(chunkCount: Int) -> Data {
        var lines = [String]()
        // Initial chunk with role
        lines.append("data: {\"id\":\"chatcmpl-perf\",\"object\":\"chat.completion.chunk\",\"created\":1677652288,\"model\":\"gpt-4o\",\"system_fingerprint\":\"fp_test\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}")
        // Content chunks
        for i in 0..<chunkCount {
            let word = "word\(i) "
            lines.append("data: {\"id\":\"chatcmpl-perf\",\"object\":\"chat.completion.chunk\",\"created\":1677652288,\"model\":\"gpt-4o\",\"system_fingerprint\":\"fp_test\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(word)\"},\"finish_reason\":null}]}")
        }
        // Final chunk
        lines.append("data: {\"id\":\"chatcmpl-perf\",\"object\":\"chat.completion.chunk\",\"created\":1677652288,\"model\":\"gpt-4o\",\"system_fingerprint\":\"fp_test\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":\(chunkCount),\"total_tokens\":\(10 + chunkCount)}}")
        lines.append("data: [DONE]")
        return lines.joined(separator: "\n\n").data(using: .utf8)!
    }

    public static func openAIToolCallStreamData(toolCount: Int) -> Data {
        var lines = [String]()
        // Initial chunk with role
        lines.append("data: {\"id\":\"chatcmpl-tool\",\"object\":\"chat.completion.chunk\",\"created\":1677652288,\"model\":\"gpt-4o\",\"system_fingerprint\":\"fp_test\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}")
        // Tool call chunks
        for i in 0..<toolCount {
            lines.append("data: {\"id\":\"chatcmpl-tool\",\"object\":\"chat.completion.chunk\",\"created\":1677652288,\"model\":\"gpt-4o\",\"system_fingerprint\":\"fp_test\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":\(i),\"id\":\"call_\(i)\",\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"\"}}]},\"finish_reason\":null}]}")
            // Arguments in chunks
            let argParts = ["{\\\"loc", "ation\\\":", " \\\"City", "\(i)\\\"", "}"]
            for part in argParts {
                lines.append("data: {\"id\":\"chatcmpl-tool\",\"object\":\"chat.completion.chunk\",\"created\":1677652288,\"model\":\"gpt-4o\",\"system_fingerprint\":\"fp_test\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":\(i),\"function\":{\"arguments\":\"\(part)\"}}]},\"finish_reason\":null}]}")
            }
        }
        lines.append("data: {\"id\":\"chatcmpl-tool\",\"object\":\"chat.completion.chunk\",\"created\":1677652288,\"model\":\"gpt-4o\",\"system_fingerprint\":\"fp_test\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":30,\"completion_tokens\":25,\"total_tokens\":55}}")
        lines.append("data: [DONE]")
        return lines.joined(separator: "\n\n").data(using: .utf8)!
    }

    public static func openAIChatCompletionRequest(messageCount: Int) -> OpenAI.ChatCompletionRequest {
        let messages: [OpenAI.Message] = (0..<messageCount).map { i in
            if i % 2 == 0 {
                return OpenAI.Message(role: .user, content: "This is test message number \(i). It contains enough text to simulate a real conversation turn with meaningful content for performance measurement.")
            } else {
                return OpenAI.Message(role: .assistant, content: "This is the assistant's response to message \(i). The response includes detailed information that would typically be returned by an LLM in a production scenario.")
            }
        }
        return OpenAI.ChatCompletionRequest(model: .gpt4o, messages: messages)
    }

    // MARK: - Anthropic Fixtures

    public static func anthropicMessageResponseJSON() -> Data {
        return """
        {
            "content": [{"text": "This is a test response from Claude with meaningful content for performance testing. The quick brown fox jumps over the lazy dog. Lorem ipsum dolor sit amet.", "type": "text"}],
            "id": "msg_perf_test_001",
            "model": "claude-sonnet-4-6",
            "role": "assistant",
            "stop_reason": "end_turn",
            "stop_sequence": null,
            "type": "message",
            "usage": {"input_tokens": 50, "output_tokens": 100}
        }
        """.data(using: .utf8)!
    }

    public static func anthropicMessageResponseWithToolsJSON(toolCount: Int) -> Data {
        var blocks = [String]()
        blocks.append("{\"text\": \"Let me help you with that.\", \"type\": \"text\"}")
        for i in 0..<toolCount {
            blocks.append("{\"type\": \"tool_use\", \"id\": \"toolu_\(i)\", \"name\": \"get_weather\", \"input\": {\"location\": \"City\(i)\", \"unit\": \"fahrenheit\"}}")
        }
        let content = blocks.joined(separator: ",\n")
        return """
        {
            "content": [\(content)],
            "id": "msg_perf_tool_test",
            "model": "claude-sonnet-4-6",
            "role": "assistant",
            "stop_reason": "tool_use",
            "stop_sequence": null,
            "type": "message",
            "usage": {"input_tokens": 100, "output_tokens": \(50 * toolCount)}
        }
        """.data(using: .utf8)!
    }

    public static func anthropicStreamData(chunkCount: Int) -> Data {
        var lines = [String]()
        lines.append("event: message_start")
        lines.append("data: {\"type\": \"message_start\", \"message\": {\"id\": \"msg_perf_stream\", \"type\": \"message\", \"role\": \"assistant\", \"content\": [], \"model\": \"claude-sonnet-4-6\", \"stop_reason\": null, \"stop_sequence\": null, \"usage\": {\"input_tokens\": 25, \"output_tokens\": 1}}}")
        lines.append("")
        lines.append("event: content_block_start")
        lines.append("data: {\"type\": \"content_block_start\", \"index\": 0, \"content_block\": {\"type\": \"text\", \"text\": \"\"}}")
        lines.append("")
        lines.append("event: ping")
        lines.append("data: {\"type\": \"ping\"}")
        lines.append("")
        for i in 0..<chunkCount {
            lines.append("event: content_block_delta")
            lines.append("data: {\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"text_delta\", \"text\": \"word\(i) \"}}")
            lines.append("")
        }
        lines.append("event: content_block_stop")
        lines.append("data: {\"type\": \"content_block_stop\", \"index\": 0}")
        lines.append("")
        lines.append("event: message_delta")
        lines.append("data: {\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"end_turn\", \"stop_sequence\": null}, \"usage\": {\"output_tokens\": \(chunkCount)}}")
        lines.append("")
        lines.append("event: message_stop")
        lines.append("data: {\"type\": \"message_stop\"}")
        return lines.joined(separator: "\n").data(using: .utf8)!
    }

    public static func anthropicMessageRequest(messageCount: Int) -> Anthropic.MessageRequest {
        let messages: [Anthropic.Message] = (0..<messageCount).map { i in
            if i % 2 == 0 {
                return Anthropic.Message(role: .user, content: "This is test message number \(i). It contains enough text to simulate a real conversation turn with meaningful content for performance measurement.")
            } else {
                return Anthropic.Message(role: .assistant, content: "This is Claude's response to message \(i). The response includes detailed information typically returned by the model in production.")
            }
        }
        return Anthropic.MessageRequest(model: .claude46Sonnet, messages: messages)
    }

    // MARK: - Shared JSON for Benchmark Comparisons

    public static let benchmarkChatResponseJSON = """
    {
        "id": "chatcmpl-benchmark",
        "object": "chat.completion",
        "created": 1677652288,
        "model": "gpt-4o-2024-08-06",
        "system_fingerprint": "fp_benchmark",
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": "The weather in San Francisco is currently 72°F with partly cloudy skies. The humidity is at 65% and winds are coming from the west at 12 mph. It's a pleasant day overall, perfect for outdoor activities."
            },
            "finish_reason": "stop"
        }],
        "usage": {
            "prompt_tokens": 25,
            "completion_tokens": 50,
            "total_tokens": 75
        }
    }
    """.data(using: .utf8)!

    public static let benchmarkAnthropicResponseJSON = """
    {
        "content": [{"text": "The weather in San Francisco is currently 72°F with partly cloudy skies. The humidity is at 65% and winds are coming from the west at 12 mph. It's a pleasant day overall, perfect for outdoor activities.", "type": "text"}],
        "id": "msg_benchmark",
        "model": "claude-sonnet-4-6",
        "role": "assistant",
        "stop_reason": "end_turn",
        "stop_sequence": null,
        "type": "message",
        "usage": {"input_tokens": 25, "output_tokens": 50}
    }
    """.data(using: .utf8)!
}
