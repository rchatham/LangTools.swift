import Foundation
import LangTools
@testable import OpenAI

/// Test-only reconstruction of the original stored fields and synthesized Encodable conformance.
/// Keep callbacks present in the layout, with the same no-op CodableIgnored encoding behavior.
struct LegacyOpenAIRequestEncoder: Encodable {
    let model: OpenAI.Model
    let messages: [OpenAI.Message]
    let temperature: Double?
    let top_p: Double?
    let n: Int?
    let stream: Bool?
    let stream_options: OpenAI.ChatCompletionRequest.StreamOptions?
    let stop: OpenAI.ChatCompletionRequest.Stop?
    let max_tokens: Int?
    let max_completion_tokens: Int?
    let presence_penalty: Double?
    let frequency_penalty: Double?
    let logit_bias: [String: Double]?
    let logprobs: Bool?
    let top_logprobs: Int?
    let user: String?
    let response_format: OpenAI.ChatCompletionRequest.ResponseFormat?
    let seed: Int?
    let tools: [OpenAI.Tool]?
    let tool_choice: OpenAI.ChatCompletionRequest.ToolChoice?
    let parallel_tool_calls: Bool?
    let service_tier: OpenAI.ChatCompletionResponse.ServiceTier?
    let store: Bool?
    let prediction: OpenAI.ChatCompletionRequest.PredictionContent?
    let modalities: [OpenAI.ChatCompletionRequest.Modality]?
    let audio: OpenAI.ChatCompletionRequest.AudioConfig?
    let reasoning_effort: OpenAI.ChatCompletionRequest.ReasoningEffort?
    let metadata: [String: String]?
    @CodableIgnored var _choose: (([OpenAI.ChatCompletionResponse.Choice]) -> Int)?
    @CodableIgnored var toolEventHandler: ((LangToolsToolEvent) -> Void)?

    init(_ request: OpenAI.ChatCompletionRequest) {
        model = request.model
        messages = request.messages
        temperature = request.temperature
        top_p = request.top_p
        n = request.n
        stream = request.stream
        stream_options = request.stream_options
        stop = request.stop
        max_tokens = request.max_tokens
        max_completion_tokens = request.max_completion_tokens
        presence_penalty = request.presence_penalty
        frequency_penalty = request.frequency_penalty
        logit_bias = request.logit_bias
        logprobs = request.logprobs
        top_logprobs = request.top_logprobs
        user = request.user
        response_format = request.response_format
        seed = request.seed
        tools = request.tools
        tool_choice = request.tool_choice
        parallel_tool_calls = request.parallel_tool_calls
        service_tier = request.service_tier
        store = request.store
        prediction = request.prediction
        modalities = request.modalities
        audio = request.audio
        reasoning_effort = request.reasoning_effort
        metadata = request.metadata
        _choose = request._choose
        toolEventHandler = request.toolEventHandler
    }
}
