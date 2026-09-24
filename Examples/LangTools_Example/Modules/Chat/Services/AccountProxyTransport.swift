import Foundation
import LangTools
import OpenAI

public protocol AccountProxyTransportProtocol {
    func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message
    func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error>
}

public protocol ConversationAwareAccountProxyTransportProtocol: AccountProxyTransportProtocol {
    func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, conversationID: UUID, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message
    func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, conversationID: UUID, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error>
    func endConversation(id: UUID) async
}

public final class AccountProxyTransport: ConversationAwareAccountProxyTransportProtocol {
    private let configurationProvider: () -> AccountBackendConfiguration
    private var configuration: AccountBackendConfiguration { configurationProvider() }
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        configuration: AccountBackendConfiguration? = nil,
        urlSession: URLSession = LoopbackURLSession.shared
    ) {
        self.configurationProvider = { configuration ?? AccountBackendConfiguration() }
        self.urlSession = urlSession
    }

    /// Allows tests to simulate a helper URL/token changing after construction.
    init(configurationProvider: @escaping () -> AccountBackendConfiguration, urlSession: URLSession) {
        self.configurationProvider = configurationProvider
        self.urlSession = urlSession
    }

    public func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message {
        let response = try await send(messages: messages, model: model, session: session, conversationID: nil, stream: false, tools: tools, toolChoice: toolChoice)
        return Message(text: response.content, role: .assistant)
    }

    public func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error> {
        makeStream(messages: messages, model: model, session: session, conversationID: nil, stream: stream, tools: tools, toolChoice: toolChoice)
    }

    public func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, conversationID: UUID, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message {
        let response = try await send(messages: messages, model: model, session: session, conversationID: conversationID, stream: false, tools: tools, toolChoice: toolChoice)
        return Message(text: response.content, role: .assistant)
    }

    public func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, conversationID: UUID, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error> {
        makeStream(messages: messages, model: model, session: session, conversationID: conversationID, stream: stream, tools: tools, toolChoice: toolChoice)
    }

    public func endConversation(id: UUID) async {
        do {
            let route = try configuration.codexHelperRoute()
            var request = URLRequest(url: route.endpoint("/v1/account/conversations/\(id.uuidString.lowercased())"))
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(route.credential.value)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await urlSession.data(for: request)
            try validate(response: response, data: data)
        } catch {
            NSLog("Unable to end Codex conversation %@: %@", id.uuidString, error.localizedDescription)
        }
    }

    private func send(messages: [Message], model: Model, session: AccountSession, conversationID: UUID?, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> AccountChatResponse {
        let isCodex: Bool
        if case .codex = model { isCodex = true } else { isCodex = false }
        let payload = AccountChatRequest(
            provider: session.provider,
            model: model.slug,
            messages: messages.map(AccountChatMessage.init),
            stream: stream,
            conversationID: isCodex ? conversationID : nil,
            toolChoice: isCodex ? nil : toolChoice.map(AccountToolChoice.init),
            tools: isCodex ? nil : tools
        )

        let request = try makeChatRequest(payload: payload, session: session)

        do {
            let (data, response) = try await urlSession.data(for: request)
            try validate(response: response, data: data)
            return try decoder.decode(AccountChatResponse.self, from: data)
        } catch let error as NetworkClient.NetworkError {
            throw error
        } catch {
            throw mapTransportError(error, provider: session.provider)
        }
    }

    private func makeStream(messages: [Message], model: Model, session: AccountSession, conversationID: UUID?, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if stream {
                        try await streamSend(messages: messages, model: model, session: session, conversationID: conversationID, tools: tools, toolChoice: toolChoice, continuation: continuation)
                    } else {
                        let response = try await send(messages: messages, model: model, session: session, conversationID: conversationID, stream: false, tools: tools, toolChoice: toolChoice)
                        continuation.yield(response.content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamSend(messages: [Message], model: Model, session: AccountSession, conversationID: UUID?, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let isCodex: Bool
        if case .codex = model { isCodex = true } else { isCodex = false }
        let payload = AccountChatRequest(
            provider: session.provider,
            model: model.slug,
            messages: messages.map(AccountChatMessage.init),
            stream: true,
            conversationID: isCodex ? conversationID : nil,
            toolChoice: isCodex ? nil : toolChoice.map(AccountToolChoice.init),
            tools: isCodex ? nil : tools
        )
        let request = try makeChatRequest(payload: payload, session: session)

        do {
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NetworkClient.NetworkError.accountProxyTransportFailed("Invalid proxy response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                try validate(response: response, data: data)
                return
            }

            var accumulated = ""
            var completed = false
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.isEmpty == false, completed == false,
                      let data = line.data(using: .utf8)
                else {
                    throw NetworkClient.NetworkError.accountProxyTransportFailed("Codex helper returned malformed NDJSON.")
                }
                let event = try decoder.decode(AccountChatStreamEvent.self, from: data)
                switch event.type {
                case .delta:
                    guard let delta = event.delta, event.content == nil, event.error == nil else {
                        throw NetworkClient.NetworkError.accountProxyTransportFailed("Codex helper returned an invalid delta event.")
                    }
                    accumulated += delta
                    continuation.yield(delta)
                case .complete:
                    guard let content = event.content, event.delta == nil, event.error == nil,
                          accumulated.isEmpty || content == accumulated
                    else {
                        throw NetworkClient.NetworkError.accountProxyTransportFailed("Codex helper returned an invalid completion event.")
                    }
                    if accumulated.isEmpty, content.isEmpty == false {
                        continuation.yield(content)
                        accumulated = content
                    }
                    completed = true
                case .error:
                    guard let message = event.error?.trimmingCharacters(in: .whitespacesAndNewlines),
                          message.isEmpty == false, event.delta == nil, event.content == nil
                    else {
                        throw NetworkClient.NetworkError.accountProxyTransportFailed("Codex helper returned an invalid error event.")
                    }
                    throw NetworkClient.NetworkError.accountProxyTransportFailed(message)
                }
            }
            guard completed else {
                throw NetworkClient.NetworkError.accountProxyTransportFailed("Codex helper ended the stream before a completion event.")
            }
        } catch let error as NetworkClient.NetworkError {
            throw error
        } catch {
            throw mapTransportError(error, provider: session.provider)
        }
    }

    private func makeChatRequest(payload: AccountChatRequest, session: AccountSession) throws -> URLRequest {
        do {
            let route = try configuration.route(for: session.provider, session: session)
            var request = URLRequest(url: route.endpoint("/account/chat/completions"))
            if route.destination == .codexHelper {
                request.url = route.endpoint("/v1/account/chat/completions")
            }
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(route.credential.value)", forHTTPHeaderField: "Authorization")
            request.httpBody = try encoder.encode(payload)
            return request
        } catch let error as AccountBackendConfigurationError {
            throw NetworkClient.NetworkError.accountProxyTransportFailed(error.localizedDescription)
        }
    }

    private func mapTransportError(_ error: Error, provider: AccountLoginProvider) -> NetworkClient.NetworkError {
        guard provider == .openAI else {
            return .accountProxyTransportFailed(error.localizedDescription)
        }

        if let urlError = error as? URLError,
           urlError.code == .cannotConnectToHost || urlError.code == .networkConnectionLost || urlError.code == .timedOut {
            return .accountProxyTransportFailed("Codex helper is not running. From the cli package, run: swift run LangToolsCLI serve")
        }

        return .accountProxyTransportFailed(error.localizedDescription)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkClient.NetworkError.accountProxyTransportFailed("Invalid proxy response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Proxy request failed with status \(httpResponse.statusCode)."
            if httpResponse.statusCode == 401 {
                throw NetworkClient.NetworkError.accountProxyTransportFailed("Codex helper rejected the request. Check the helper token in Settings.")
            }
            throw NetworkClient.NetworkError.accountProxyTransportFailed(message)
        }
    }
}

private struct AccountChatRequest: Encodable {
    let provider: AccountLoginProvider
    let model: String
    let messages: [AccountChatMessage]
    let stream: Bool
    let conversationID: UUID?
    let toolChoice: AccountToolChoice?
    let tools: [Tool]?
}

private struct AccountChatMessage: Codable {
    let role: String
    let content: String

    init(_ message: Message) {
        self.role = message.role.rawValue
        self.content = message.providerContext ?? ""
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

private struct AccountChatStreamEvent: Decodable {
    enum Kind: String, Decodable {
        case delta
        case complete
        case error
    }

    let type: Kind
    let delta: String?
    let content: String?
    let error: String?
}
