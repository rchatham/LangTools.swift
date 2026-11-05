//
//  ChatCompletionResponseTests.swift
//  OpenAITests
//
//  Created by Reid Chatham on 12/15/23.
//

import XCTest
@testable import TestUtils
@testable import OpenAI

final class ChatCompletionResponseTests: XCTestCase {
    func testChatCompletionResponseDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.ChatCompletionResponse, Error>) in
            switch result {
            case .success(let response):
                XCTAssert(
                    response.id == "chatcmpl-123" &&
                    response.model == "gpt-3.5-turbo-0613" &&
                    response.system_fingerprint == "fp_44709d6fcb" &&
                    response.service_tier == .default
                )
                XCTAssertEqual(response.choices[0].logprobs?.content?.first?.token, "Hello")
                XCTAssertEqual(response.choices[0].logprobs?.content?.first?.logprob, -0.5)
                XCTAssertEqual(response.usage?.completion_tokens_details?.reasoning_tokens, 5)
                XCTAssertEqual(response.usage?.completion_tokens_details?.accepted_prediction_tokens, 3)
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "chat_completion_response")!)
    }

    func testChatCompletionResponseWithToolCallDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.ChatCompletionResponse, Error>) in
            switch result {
            case .success(let response):
                XCTAssertEqual(response.system_fingerprint, "fp_44709d6fcb")
                XCTAssertEqual(response.service_tier, .default)
                XCTAssertEqual(response.usage?.completion_tokens_details?.reasoning_tokens, 10)
                XCTAssertEqual(response.choices[0].finish_reason, .tool_calls)
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "chat_completion_response_tool_call")!)
    }

    func testChatCompletionResponseEncodable() throws {
        let response = OpenAI.ChatCompletionResponse(
            id: "chatcmpl-123",
            object: "chat.completion",
            created: 1677652288,
            model: "gpt-3.5-turbo-0613",
            system_fingerprint: "fp_44709d6fcb",
            choices: [.init(
                index: 0,
                message: .init(
                    role: .assistant,
                    content: "Hello there, how may I assist you today?"),
                finish_reason: .stop,
                delta: nil,
                logprobs: nil)
            ],
            usage: .init(
                prompt_tokens: 9,
                completion_tokens: 12,
                total_tokens: 21),
            service_tier: nil,
            choose: {_ in 0}
        )
        let data = try response.data()
        let testData = try getData(filename: "chat_completion_response")!
        XCTAssert(data.dictionary == testData.dictionary, "failed to correctly encode the data")
    }

    // MARK: - Streaming Response Combining

    /// Builds a single streaming chunk carrying one content delta, mirroring what the SSE
    /// decoder produces per line.
    private func streamChunk(_ content: String, role: OpenAI.Message.Role? = nil) -> OpenAI.ChatCompletionResponse {
        OpenAI.ChatCompletionResponse(
            id: "chunk",
            object: "chat.completion.chunk",
            created: 0,
            model: "gpt-4",
            system_fingerprint: nil,
            choices: [.init(
                index: 0,
                message: nil,
                finish_reason: nil,
                delta: .init(role: role, content: content, tool_calls: nil, audio: nil, refusal: nil),
                logprobs: nil)],
            usage: nil,
            service_tier: nil,
            choose: { _ in 0 })
    }

    /// Regression test for the operator-precedence bug in `combining(_:with:)` where
    /// `a ?? "" + (b ?? "")` parsed as `a ?? ("" + (b ?? ""))`, silently dropping every content
    /// delta after `message` became non-nil. This folds chunks exactly as `LangTools.stream`
    /// does (`combinedResponse = combinedResponse.combining(with:)`) and asserts the *combined*
    /// `message.content` — the field consumers never read per-chunk, which is why the bug hid.
    func testStreamingContentAccumulation() throws {
        let parts = ["Hello", ", ", "world", "!"]
        var combined = OpenAI.ChatCompletionResponse.empty
        for (i, part) in parts.enumerated() {
            combined = combined.combining(with: streamChunk(part, role: i == 0 ? .assistant : nil))
        }

        let choice = try XCTUnwrap(combined.choices.first)
        XCTAssertEqual(choice.message?.content.string, "Hello, world!",
                       "combined message.content must be the full concatenation of every delta")
        XCTAssertEqual(choice.delta?.content, "Hello, world!",
                       "accumulated delta.content must also be the full concatenation")
        XCTAssertEqual(choice.message?.role, .assistant)
    }

    private func streamChunk(index: Int, content: String) -> OpenAI.ChatCompletionResponse {
        OpenAI.ChatCompletionResponse(
            id: "chunk",
            object: "chat.completion.chunk",
            created: 0,
            model: "gpt-4",
            system_fingerprint: nil,
            choices: [.init(
                index: index,
                message: nil,
                finish_reason: nil,
                delta: .init(role: .assistant, content: content, tool_calls: nil, audio: nil, refusal: nil),
                logprobs: nil)],
            usage: nil,
            service_tier: nil,
            choose: { _ in 0 })
    }

    private func terminalUsageChunk() -> OpenAI.ChatCompletionResponse {
        // Real OpenAI streams end with a choices:[] chunk carrying only usage — this is the
        // `next.isEmpty` path in `combining(_ choices:with:)`.
        OpenAI.ChatCompletionResponse(
            id: "chunk-final",
            object: "chat.completion.chunk",
            created: 0,
            model: "gpt-4",
            system_fingerprint: nil,
            choices: [],
            usage: .init(prompt_tokens: 1, completion_tokens: 1, total_tokens: 2),
            service_tier: nil,
            choose: { _ in 0 })
    }

    /// Regression test for the `isSortedByIndex` fast path in `combining(_ choices:with:)`.
    /// Choice index 1 arriving before index 0 across chunks makes the accumulator's internal
    /// order `[1, 0]` (the merge appends unmatched indices to the end); the old
    /// `if next.isEmpty { return choices }` shipped that unsorted array unchanged on the
    /// terminal usage-only chunk (`next.isEmpty`, which is the common case for real streams).
    /// The fix re-checks `isSortedByIndex` on that path so the accumulator still self-heals.
    /// The first-chunk counterpart of the terminal-chunk regression test below: a single chunk
    /// carrying multiple out-of-order choices, combined into `.empty` with no further chunks.
    /// The `choices.isEmpty` early return must establish the sorted invariant itself — there is
    /// no subsequent combine to self-heal it.
    func testFirstChunkMultiChoiceArrivesSorted() throws {
        let chunk = OpenAI.ChatCompletionResponse(
            id: "chunk",
            object: "chat.completion.chunk",
            created: 0,
            model: "gpt-4",
            system_fingerprint: nil,
            choices: [
                .init(index: 1, message: nil, finish_reason: nil,
                      delta: .init(role: .assistant, content: "B", tool_calls: nil, audio: nil, refusal: nil),
                      logprobs: nil),
                .init(index: 0, message: nil, finish_reason: nil,
                      delta: .init(role: .assistant, content: "A", tool_calls: nil, audio: nil, refusal: nil),
                      logprobs: nil),
            ],
            usage: nil,
            service_tier: nil,
            choose: { _ in 0 })

        let combined = OpenAI.ChatCompletionResponse.empty.combining(with: chunk)
        XCTAssertEqual(combined.choices.map(\.index), [0, 1],
                       "a first chunk with out-of-order choices must come back sorted even when it is the only chunk")
        XCTAssertEqual(combined.choices.first(where: { $0.index == 0 })?.delta?.content, "A")
        XCTAssertEqual(combined.choices.first(where: { $0.index == 1 })?.delta?.content, "B")
    }

    private func toolCallChunk(toolIndex: Int, id: String, name: String) -> OpenAI.ChatCompletionResponse {
        OpenAI.ChatCompletionResponse(
            id: "chunk",
            object: "chat.completion.chunk",
            created: 0,
            model: "gpt-4",
            system_fingerprint: nil,
            choices: [.init(
                index: 0,
                message: nil,
                finish_reason: nil,
                delta: .init(role: .assistant, content: nil,
                             tool_calls: [.init(index: toolIndex, id: id, type: .function,
                                                function: .init(name: name, arguments: "{}"))],
                             audio: nil, refusal: nil),
                logprobs: nil)],
            usage: nil,
            service_tier: nil,
            choose: { _ in 0 })
    }

    private func finishChunk(reason: OpenAI.ChatCompletionResponse.Choice.FinishReason) -> OpenAI.ChatCompletionResponse {
        // Terminal delta chunk: same choice index, but `tool_calls` is absent (decodes as nil,
        // not []) — the nil path of `combining(_ toolCalls:with:)`.
        OpenAI.ChatCompletionResponse(
            id: "chunk-finish",
            object: "chat.completion.chunk",
            created: 0,
            model: "gpt-4",
            system_fingerprint: nil,
            choices: [.init(
                index: 0,
                message: nil,
                finish_reason: reason,
                delta: .init(role: nil, content: nil, tool_calls: nil, audio: nil, refusal: nil),
                logprobs: nil)],
            usage: nil,
            service_tier: nil,
            choose: { _ in 0 })
    }

    /// Mirror of `testStreamingMultiChoiceRemainsSortedThroughTerminalUsageChunk` for the
    /// `[Message.ToolCall]` combiner: tool-call index 1 arriving before index 0 leaves the
    /// accumulator internally ordered `[1, 0]`, and the terminal finish chunk carries
    /// `tool_calls: nil` — the combiner's nil path, which previously returned the surviving
    /// array unchanged instead of self-healing like the merge path does.
    func testStreamingToolCallsRemainSortedThroughTerminalDelta() throws {
        var combined = OpenAI.ChatCompletionResponse.empty
        combined = combined.combining(with: toolCallChunk(toolIndex: 1, id: "call_b", name: "tool_b"))
        combined = combined.combining(with: toolCallChunk(toolIndex: 0, id: "call_a", name: "tool_a"))
        combined = combined.combining(with: finishChunk(reason: .tool_calls))

        let choice = try XCTUnwrap(combined.choices.first)
        XCTAssertEqual(choice.delta?.tool_calls?.map(\.index), [0, 1],
                       "accumulated tool_calls must be sorted by index after the nil-tool_calls terminal delta")
        XCTAssertEqual(choice.delta?.tool_calls?.map(\.id), ["call_a", "call_b"])
        XCTAssertEqual(choice.message?.tool_calls?.map(\.index), [0, 1],
                       "combined message.tool_calls must also come back sorted")
    }

    func testStreamingMultiChoiceRemainsSortedThroughTerminalUsageChunk() throws {
        var combined = OpenAI.ChatCompletionResponse.empty
        combined = combined.combining(with: streamChunk(index: 1, content: "B"))
        combined = combined.combining(with: streamChunk(index: 0, content: "A"))
        combined = combined.combining(with: terminalUsageChunk())

        XCTAssertEqual(combined.choices.map(\.index), [0, 1],
                       "choices must be sorted by index after combining, even through the empty-choices terminal chunk")
        XCTAssertEqual(combined.choices.first(where: { $0.index == 0 })?.delta?.content, "A")
        XCTAssertEqual(combined.choices.first(where: { $0.index == 1 })?.delta?.content, "B")
    }

    // MARK: - Single-chunk stream settle

    /// A canonical first-arrival chunk. With the default index it models a single-chunk SSE
    /// stream (the whole completion arrives as one chunk); a non-default index models a choice
    /// unseen in the accumulator, which must settle the same way.
    private func singleChunk(index: Int = 0, delta: OpenAI.Message.Delta?, finishReason: OpenAI.ChatCompletionResponse.Choice.FinishReason?, logprobs: OpenAI.ChatCompletionResponse.Choice.LogProbs? = nil) -> OpenAI.ChatCompletionResponse {
        OpenAI.ChatCompletionResponse(
            id: "chunk",
            object: "chat.completion.chunk",
            created: 0,
            model: "gpt-4",
            system_fingerprint: nil,
            choices: [.init(
                index: index,
                message: nil,
                finish_reason: finishReason,
                delta: delta,
                logprobs: logprobs)],
            usage: nil,
            service_tier: nil,
            choose: { _ in 0 })
    }

    /// Regression for the CI-blocking P1: a compliant server may send the entire response
    /// as one SSE chunk. The first-chunk combine must settle the sole delta into `message` —
    /// previously the delta→message fold only ran when a later chunk combined, so a
    /// single-chunk tool-call stream reached EOF with `message == nil` and the tool
    /// completion request was silently skipped. Combining-level counterpart of
    /// `LangToolsTransportTests.testBodyOverrideDispatchesForRecursiveProviderCompletion`.
    func testSingleChunkToolCallStreamSettlesMessage() throws {
        let logprobs = OpenAI.ChatCompletionResponse.Choice.LogProbs(
            content: [.init(token: "echo", logprob: -0.5, bytes: nil, top_logprobs: nil)],
            refusal: nil)
        let toolDelta = OpenAI.Message.Delta(
            role: .assistant,
            content: "",
            tool_calls: [.init(index: 0, id: "call-1", type: .function,
                                function: .init(name: "echo", arguments: "{}"))],
            audio: nil, refusal: nil)
        let combined = OpenAI.ChatCompletionResponse.empty.combining(
            with: singleChunk(delta: toolDelta, finishReason: .tool_calls, logprobs: logprobs))

        let choice = try XCTUnwrap(combined.choices.first)
        let message = try XCTUnwrap(choice.message, "a single-chunk stream must settle its delta into message")
        XCTAssertEqual(message.role, .assistant)
        let toolCalls = try XCTUnwrap(message.tool_calls)
        XCTAssertEqual(toolCalls.count, 1, "settling must not duplicate the tool call")
        XCTAssertEqual(toolCalls.first?.id, "call-1")
        XCTAssertEqual(toolCalls.first?.name, "echo")
        XCTAssertEqual(toolCalls.first?.arguments, "{}")
        XCTAssertEqual(choice.finish_reason, .tool_calls, "a single chunk's finish_reason must not be dropped")
        XCTAssertEqual(choice.delta?.tool_calls?.count, 1, "delta is preserved for OpenAI API consistency")
        XCTAssertEqual(choice.delta?.tool_calls?.first?.id, "call-1")
        XCTAssertEqual(choice.logprobs?.content?.first?.token, "echo", "settlement must preserve non-nil logprobs")
        XCTAssertEqual(choice.logprobs?.content?.first?.logprob, -0.5)
    }

    /// The text counterpart of the single-chunk settle: content, role, finish_reason, and
    /// the preserved delta must all survive the first-chunk fold.
    func testSingleChunkTextStreamSettlesMessage() throws {
        let textDelta = OpenAI.Message.Delta(role: .assistant, content: "Hello!", tool_calls: nil, audio: nil, refusal: nil)
        let combined = OpenAI.ChatCompletionResponse.empty.combining(
            with: singleChunk(delta: textDelta, finishReason: .stop))

        let choice = try XCTUnwrap(combined.choices.first)
        let message = try XCTUnwrap(choice.message)
        XCTAssertEqual(message.content.string, "Hello!")
        XCTAssertEqual(message.role, .assistant)
        XCTAssertNil(message.tool_calls)
        XCTAssertEqual(choice.finish_reason, .stop)
        XCTAssertEqual(choice.delta?.content, "Hello!")
    }

    /// Non-stream message preservation: a response carrying a complete `message` with no
    /// delta (the non-streaming `chat.completion` shape) must pass through the first-chunk
    /// combine verbatim — kept, never re-folded, no invented delta, finish_reason intact.
    func testMessageBearingResponseCombinedAsFirstChunkPreservesMessage() throws {
        let nonStream = OpenAI.ChatCompletionResponse(
            id: "chatcmpl-1",
            object: "chat.completion",
            created: 0,
            model: "gpt-4",
            system_fingerprint: nil,
            choices: [.init(
                index: 0,
                message: OpenAI.Message(tool_selection: [
                    .init(index: 0, id: "call-1", type: .function, function: .init(name: "echo", arguments: "{}"))
                ]),
                finish_reason: .tool_calls,
                delta: nil,
                logprobs: nil)],
            usage: nil,
            service_tier: nil,
            choose: { _ in 0 })

        let combined = OpenAI.ChatCompletionResponse.empty.combining(with: nonStream)
        let choice = try XCTUnwrap(combined.choices.first)
        XCTAssertEqual(choice.finish_reason, .tool_calls)
        XCTAssertNil(choice.delta, "a message-only response must not gain a delta")
        XCTAssertEqual(choice.message?.role, .assistant)
        let toolCalls = try XCTUnwrap(choice.message?.tool_calls)
        XCTAssertEqual(toolCalls.count, 1, "an already-materialized message must not be re-folded")
        XCTAssertEqual(toolCalls.first?.id, "call-1")
    }

    /// Canonical multi-chunk tool-call stream against the settled first chunk: an empty-delta
    /// terminal chunk carrying `finish_reason` and a usage-only terminal chunk must neither
    /// duplicate the settled tool call nor drop the finish_reason.
    func testSettledToolCallsSurviveCanonicalFinishAndUsageChunks() throws {
        var combined = OpenAI.ChatCompletionResponse.empty
        combined = combined.combining(with: toolCallChunk(toolIndex: 0, id: "call-1", name: "echo"))
        combined = combined.combining(with: finishChunk(reason: .tool_calls))
        combined = combined.combining(with: terminalUsageChunk())

        let choice = try XCTUnwrap(combined.choices.first)
        XCTAssertEqual(choice.finish_reason, .tool_calls, "the terminal finish_reason must not be dropped")
        let toolCalls = try XCTUnwrap(choice.message?.tool_calls)
        XCTAssertEqual(toolCalls.count, 1, "settle plus finish chunk must not duplicate the tool call")
        XCTAssertEqual(toolCalls.first?.id, "call-1")
        XCTAssertEqual(toolCalls.first?.name, "echo")
        XCTAssertEqual(toolCalls.first?.arguments, "{}")
    }

    /// A new choice index arriving mid-stream must append (not merge into the settled choice)
    /// and settle immediately on first arrival — it must not depend on a later same-index chunk
    /// to materialize its message. The subsequent same-index chunk then proves no duplication.
    func testSettledAccumulatorAppendsNewChoiceIndex() throws {
        var combined = OpenAI.ChatCompletionResponse.empty
        combined = combined.combining(with: streamChunk(index: 0, content: "A"))
        combined = combined.combining(with: streamChunk(index: 1, content: "B"))

        XCTAssertEqual(combined.choices.map(\.index), [0, 1])
        XCTAssertEqual(combined.choices.first?.message?.content.string, "A")
        XCTAssertEqual(combined.choices.last?.message?.content.string, "B",
                       "a newly appended choice index must settle on first arrival")
        XCTAssertEqual(combined.choices.first?.delta?.content, "A")
        XCTAssertEqual(combined.choices.last?.delta?.content, "B")

        // A subsequent chunk for the same index folds into the settled message without duplication.
        combined = combined.combining(with: streamChunk(index: 1, content: "!"))
        XCTAssertEqual(combined.choices.last?.message?.content.string, "B!")
        XCTAssertEqual(combined.choices.last?.delta?.content, "B!")
    }

    /// Sparse choice indexes must accumulate without inventing intermediate choices; the sparse
    /// choice settles immediately on first arrival, and both settled messages and the sparse
    /// choice's non-nil logprobs survive the terminal usage-only chunk.
    func testSparseChoiceIndexesAccumulateWithoutInventingIntermediateChoices() throws {
        let sparseLogprobs = OpenAI.ChatCompletionResponse.Choice.LogProbs(
            content: [.init(token: "C", logprob: -0.25, bytes: nil, top_logprobs: nil)],
            refusal: nil)
        var combined = OpenAI.ChatCompletionResponse.empty
        combined = combined.combining(with: streamChunk(index: 0, content: "A"))
        combined = combined.combining(
            with: singleChunk(index: 2,
                              delta: .init(role: .assistant, content: "C", tool_calls: nil, audio: nil, refusal: nil),
                              finishReason: nil,
                              logprobs: sparseLogprobs))

        XCTAssertEqual(combined.choices.map(\.index), [0, 2],
                       "sparse indexes must not invent intermediate choices")
        XCTAssertEqual(combined.choices.count, 2)
        XCTAssertEqual(combined.choices.first?.message?.content.string, "A")
        XCTAssertEqual(combined.choices.last?.message?.content.string, "C",
                       "a sparse first arrival must settle its message")
        XCTAssertEqual(combined.choices.last?.delta?.content, "C")

        combined = combined.combining(with: terminalUsageChunk())
        XCTAssertEqual(combined.choices.first?.message?.content.string, "A",
                       "settled messages must survive the usage-only terminal chunk")
        XCTAssertEqual(combined.choices.last?.message?.content.string, "C",
                       "settled messages must survive the usage-only terminal chunk")
        XCTAssertEqual(combined.choices.last?.logprobs?.content?.first?.token, "C",
                       "settlement of an appended choice must preserve non-nil logprobs")
        XCTAssertEqual(combined.choices.last?.logprobs?.content?.first?.logprob, -0.25)
    }
}
