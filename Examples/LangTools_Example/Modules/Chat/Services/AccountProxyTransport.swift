import Foundation
import LangTools
import OpenAI

public protocol AccountProxyTransportProtocol {
    func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message
    func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error>
}

public final class AccountProxyTransport: AccountProxyTransportProtocol {
    private let configuration: AccountBackendConfiguration
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        configuration: AccountBackendConfiguration = AccountBackendConfiguration(),
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    public func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message {
        let response = try await send(messages: messages, model: model, session: session, stream: false, tools: tools, toolChoice: toolChoice)
        return Message(text: response.content, role: .assistant)
    }

    public func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await send(messages: messages, model: model, session: session, stream: stream, tools: tools, toolChoice: toolChoice)
                    continuation.yield(response.content)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func send(messages: [Message], model: Model, session: AccountSession, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> AccountChatResponse {
        let payload = AccountChatRequest(
            provider: session.provider,
            model: model.rawValue,
            messages: messages.map(AccountChatMessage.init),
            stream: stream,
            toolChoice: toolChoice.map(AccountToolChoice.init),
            tools: tools
        )

        var request = URLRequest(url: configuration.accountChatURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(AccountChatResponse.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkClient.NetworkError.accountProxyTransportFailed("Invalid proxy response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Proxy request failed with status \(httpResponse.statusCode)."
            throw NetworkClient.NetworkError.accountProxyTransportFailed(message)
        }
    }
}

private struct AccountChatRequest: Encodable {
    let provider: AccountLoginProvider
    let model: String
    let messages: [AccountChatMessage]
    let stream: Bool
    let toolChoice: AccountToolChoice?
    let tools: [Tool]?
}

private struct AccountChatMessage: Codable {
    let role: String
    let content: String

    init(_ message: Message) {
        self.role = message.role.rawValue
        self.content = message.text ?? ""
    }
}

private struct AccountToolChoice: Codable {
    let mode: String
    let toolName: String?

    init(_ toolChoice: OpenAI.ChatCompletionRequest.ToolChoice) {
        switch toolChoice {
        case .none:
            self.mode = "none"
            self.toolName = nil
        case .auto:
            self.mode = "auto"
            self.toolName = nil
        case .required:
            self.mode = "required"
            self.toolName = nil
        case .tool(let wrapper):
            self.mode = "tool"
            switch wrapper {
            case .function(let name):
                self.toolName = name
            }
        }
    }
}

private struct AccountChatResponse: Codable {
    let content: String
}
