import ChatUI
import LangTools

extension LangToolsRequestError {
    /// The app's request-error presentation, compiled with the Chat package so
    /// newly added request errors cannot escape its exhaustive-switch coverage.
    public var chatAlertInfo: ChatAlertInfo {
        switch self {
        case .multipleChoiceIndexOutOfBounds:
            return ChatAlertInfo(title: "Invalid Selection", message: "The selected choice was out of bounds.")
        case .failedToDecodeFunctionArguments:
            return ChatAlertInfo(title: "Decoding Error", message: "Failed to decode function arguments.")
        case .missingRequiredFunctionArguments:
            return ChatAlertInfo(title: "Missing Arguments", message: "Required function arguments are missing.")
        case .toolIterationLimitReached:
            return ChatAlertInfo(title: "Tool Iteration Limit", message: localizedDescription)
        }
    }
}
