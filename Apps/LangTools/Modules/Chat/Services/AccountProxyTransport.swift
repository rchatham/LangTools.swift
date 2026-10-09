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
    private let selections: AccountTransportSelectionStore
    private let conversationLock = NSLock()
    private var conversationRoutes: [UUID: [CapturedRoute]] = [:]
    private let encoder = JSONEncoder()

    private struct CapturedRoute {
        let local: AccountBackendRoute?
        let paired: PairedAccountRoute?
        let urlSession: URLSession
        var chatPath: String {
            if let paired { return paired.snapshot.provider == .openAI ? "/v1/account/chat/completions" : "/v1/claude/chat/completions" }
            return local?.destination == .codexHelper ? "/v1/account/chat/completions" : "/account/chat/completions"
        }
        func request(path: String, method: String) -> URLRequest {
            if let paired { return paired.request(path: path, method: method) }
            var request = URLRequest(url: local!.endpoint(path))
            request.httpMethod = method
            request.setValue("Bearer \(local!.credential.value)", forHTTPHeaderField: "Authorization")
            return request
        }
    }
    private let decoder = JSONDecoder()

    /// Capture from the authorization/catalog snapshot, never from a second
    /// settings read after the caller crosses an async transport boundary.
    func capturingRoute(session: AccountSession, snapshot: AccountTransportSelectionStore.Snapshot) throws -> AccountProxyTransportProtocol {
        guard snapshot.provider == session.provider else { throw NetworkClient.NetworkError.incompatibleRequest }
        return BoundTransport(owner: self, session: session, route: try captureRoute(session: session, snapshot: snapshot))
    }

    private final class BoundTransport: ConversationAwareAccountProxyTransportProtocol {
        let owner: AccountProxyTransport
        let session: AccountSession
        let route: CapturedRoute
        init(owner: AccountProxyTransport, session: AccountSession, route: CapturedRoute) {
            self.owner = owner; self.session = session; self.route = route
        }
        func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message {
            let response = try await owner.send(messages: messages, model: model, session: self.session, conversationID: nil, stream: false, tools: tools, toolChoice: toolChoice, capturedRoute: route)
            return Message(text: response.content, role: .assistant)
        }
        func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error> {
            try owner.makeStream(messages: messages, model: model, session: self.session, conversationID: nil, stream: stream, tools: tools, toolChoice: toolChoice, capturedRoute: route)
        }
        func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, conversationID: UUID, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message {
            let response = try await owner.send(messages: messages, model: model, session: self.session, conversationID: conversationID, stream: false, tools: tools, toolChoice: toolChoice, capturedRoute: route)
            return Message(text: response.content, role: .assistant)
        }
        func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, conversationID: UUID, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error> {
            try owner.makeStream(messages: messages, model: model, session: self.session, conversationID: conversationID, stream: stream, tools: tools, toolChoice: toolChoice, capturedRoute: route)
        }
        func endConversation(id: UUID) async { await owner.endConversation(id: id) }
    }

    public init(
        configuration: AccountBackendConfiguration? = nil,
        urlSession: URLSession = LoopbackURLSession.shared,
        selections: AccountTransportSelectionStore = .shared
    ) {
        self.configurationProvider = { configuration ?? AccountBackendConfiguration() }
        self.urlSession = urlSession
        self.selections = selections
    }

    /// Allows tests to simulate a helper URL/token changing after construction.
    init(configurationProvider: @escaping () -> AccountBackendConfiguration, urlSession: URLSession, selections: AccountTransportSelectionStore = .shared) {
        self.configurationProvider = configurationProvider
        self.urlSession = urlSession
        self.selections = selections
    }

    public func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message {
        let response = try await send(messages: messages, model: model, session: session, conversationID: nil, stream: false, tools: tools, toolChoice: toolChoice)
        return Message(text: response.content, role: .assistant)
    }

    public func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error> {
        try makeStream(messages: messages, model: model, session: session, conversationID: nil, stream: stream, tools: tools, toolChoice: toolChoice)
    }

    public func performChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, conversationID: UUID, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) async throws -> Message {
        let response = try await send(messages: messages, model: model, session: session, conversationID: conversationID, stream: false, tools: tools, toolChoice: toolChoice)
        return Message(text: response.content, role: .assistant)
    }

    public func streamChatCompletionRequest(messages: [Message], model: Model, session: AccountSession, conversationID: UUID, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?) throws -> AsyncThrowingStream<String, Error> {
        try makeStream(messages: messages, model: model, session: session, conversationID: conversationID, stream: stream, tools: tools, toolChoice: toolChoice)
    }

    public func endConversation(id: UUID) async {
        do {
            let routes = try takeConversationRoutes(id) ?? [captureCodexRoute()]
            for route in routes {
                do {
                    let request = route.request(path: "/v1/account/conversations/\(id.uuidString.lowercased())", method: "DELETE")
                    let (data, response) = try await route.urlSession.data(for: request,
                        delegate: route.urlSession.delegate as? any URLSessionTaskDelegate)
                    if let paired = route.paired { try paired.validate(response) }
                    else { try validate(response: response, data: data) }
                } catch {
                    NSLog("Unable to end Codex conversation %@: %@", id.uuidString, error.localizedDescription)
                }
            }
        } catch {
            NSLog("Unable to resolve Codex conversation cleanup %@: %@", id.uuidString, error.localizedDescription)
        }
    }

    private func send(messages: [Message], model: Model, session: AccountSession, conversationID: UUID?, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, capturedRoute: CapturedRoute? = nil) async throws -> AccountChatResponse {
        let route = try capturedRoute ?? captureRoute(session: session)
        rememberRoute(route, provider: session.provider, conversationID: conversationID)
        let isCodex: Bool
        if case .codex = model { isCodex = true } else { isCodex = false }
        let payload = AccountChatRequest(
            provider: session.provider,
            model: model.slug,
            messages: messages.toAccountChatMessages(),
            stream: stream,
            conversationID: isCodex ? conversationID : nil,
            toolChoice: isCodex ? nil : toolChoice.map(AccountToolChoice.init),
            tools: isCodex ? nil : tools
        )

        let request = try makeChatRequest(payload: payload, route: route)

        do {
            let (data, response) = try await route.urlSession.data(for: request,
                delegate: route.urlSession.delegate as? any URLSessionTaskDelegate)
            if let paired = route.paired { try paired.validate(response) }
            else { try validate(response: response, data: data) }
            return try decoder.decode(AccountChatResponse.self, from: data)
        } catch {
            if route.paired == nil, let error = error as? NetworkClient.NetworkError { throw error }
            throw transportError(error, route: route, provider: session.provider)
        }
    }

    private func makeStream(messages: [Message], model: Model, session: AccountSession, conversationID: UUID?, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, capturedRoute: CapturedRoute? = nil) throws -> AsyncThrowingStream<String, Error> {
        // Capture synchronously, before the stream task can race a selection change.
        let route = try capturedRoute ?? captureRoute(session: session)
        rememberRoute(route, provider: session.provider, conversationID: conversationID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if stream {
                        try await streamSend(messages: messages, model: model, session: session, conversationID: conversationID, tools: tools, toolChoice: toolChoice, continuation: continuation, route: route)
                    } else {
                        let response = try await send(messages: messages, model: model, session: session, conversationID: conversationID, stream: false, tools: tools, toolChoice: toolChoice, capturedRoute: route)
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

    private func streamSend(messages: [Message], model: Model, session: AccountSession, conversationID: UUID?, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, continuation: AsyncThrowingStream<String, Error>.Continuation, route: CapturedRoute) async throws {
        let isCodex: Bool
        if case .codex = model { isCodex = true } else { isCodex = false }
        let payload = AccountChatRequest(
            provider: session.provider,
            model: model.slug,
            messages: messages.toAccountChatMessages(),
            stream: true,
            conversationID: isCodex ? conversationID : nil,
            toolChoice: isCodex ? nil : toolChoice.map(AccountToolChoice.init),
            tools: isCodex ? nil : tools
        )
        let request = try makeChatRequest(payload: payload, route: route)

        do {
            let (bytes, response) = try await route.urlSession.bytes(for: request,
                delegate: route.urlSession.delegate as? any URLSessionTaskDelegate)
            if let paired = route.paired { try paired.validate(response) }
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
        } catch {
            if route.paired == nil, let error = error as? NetworkClient.NetworkError { throw error }
            throw transportError(error, route: route, provider: session.provider)
        }
    }

    private func makeChatRequest(payload: AccountChatRequest, route: CapturedRoute) throws -> URLRequest {
        var request = route.request(path: route.chatPath, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)
        return request
    }

    private func captureRoute(session: AccountSession, snapshot capturedSnapshot: AccountTransportSelectionStore.Snapshot? = nil) throws -> CapturedRoute {
        let snapshot = capturedSnapshot ?? selections.snapshot(for: session.provider)
        let route: CapturedRoute
        if snapshot.isPaired {
            let paired = try PairedAccountRoute(snapshot: snapshot, session: session)
            route = CapturedRoute(local: nil, paired: paired, urlSession: paired.connection.session)
        } else {
            do {
                route = CapturedRoute(local: try configuration.route(for: session.provider, session: session), paired: nil, urlSession: urlSession)
            } catch let error as AccountBackendConfigurationError {
                throw NetworkClient.NetworkError.accountProxyTransportFailed(error.localizedDescription)
            }
        }
        return route
    }

    private func rememberRoute(_ route: CapturedRoute, provider: AccountLoginProvider, conversationID: UUID?) {
        if let conversationID, provider == .openAI {
            conversationLock.lock()
            var owners = conversationRoutes[conversationID] ?? []
            if !owners.contains(where: { owner in
                if let paired = route.paired { return owner.paired?.connection === paired.connection }
                return owner.paired == nil && owner.local == route.local
            }) { owners.append(route) }
            conversationRoutes[conversationID] = owners
            conversationLock.unlock()
        }
    }

    private func captureCodexRoute() throws -> CapturedRoute {
        let snapshot = selections.snapshot(for: .openAI)
        if snapshot.isPaired {
            let paired = try PairedAccountRoute(snapshot: snapshot, session: nil)
            return CapturedRoute(local: nil, paired: paired, urlSession: paired.connection.session)
        }
        return CapturedRoute(local: try configuration.codexHelperRoute(), paired: nil, urlSession: urlSession)
    }

    private func takeConversationRoutes(_ id: UUID) -> [CapturedRoute]? {
        conversationLock.lock(); defer { conversationLock.unlock() }
        return conversationRoutes.removeValue(forKey: id)
    }

    private func transportError(_ error: Error, route: CapturedRoute, provider: AccountLoginProvider) -> Error {
        if let paired = route.paired {
            let mapped = paired.snapshot.actionableError(error)
            // Darwin reports ordinary task cancellation and pin rejection as
            // -999. Only the recorded trust rejection invalidates the route.
            if error is CancellationError || ((error as? URLError)?.code == .cancelled &&
                (paired.connection.session.delegate as? MobileHelperSessionDelegate)?.hasRejectedTrust != true) {
                return error
            }
            _ = selections.fail(mapped, for: paired.snapshot)
            return paired.snapshot.actionableError(error)
        }
        return mapTransportError(error, provider: provider)
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
    // Additive, backward-compatible fields for tool-call history replay. Both
    // are omitted from the wire payload when nil, so older backends that do not
    // understand tool calls are unaffected.
    let tool_calls: [AccountToolCall]?
    let tool_call_id: String?

    init(_ message: Message) {
        self.role = message.role.rawValue
        self.content = message.providerContext ?? ""
        self.tool_calls = nil
        self.tool_call_id = nil
    }

    init(role: String, content: String, tool_calls: [AccountToolCall]? = nil, tool_call_id: String? = nil) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
    }
}

private struct AccountToolCall: Codable {
    let id: String
    let type: String
    let function: Function

    struct Function: Codable {
        let name: String
        let arguments: String
    }
}

private extension Array where Element == Message {
    /// Replays retained tool calls as an assistant tool-call message followed by
    /// tool-result messages, mirroring `toOpenAIMessages()` for the account proxy
    /// wire schema. Messages without completed tool calls pass through unchanged.
    func toAccountChatMessages() -> [AccountChatMessage] {
        flatMap { message -> [AccountChatMessage] in
            let calls = message.toolCalls.filter { $0.status != .pending }
            guard !calls.isEmpty else { return [AccountChatMessage(message)] }
            let assistant = AccountChatMessage(
                role: "assistant",
                content: message.providerContext ?? "",
                tool_calls: calls.map { call in
                    AccountToolCall(
                        id: call.id,
                        type: "function",
                        function: .init(name: call.name, arguments: call.arguments ?? "{}")
                    )
                }
            )
            let results = calls.map { call in
                AccountChatMessage(
                    role: "tool",
                    content: message.providerToolResults[call.id] ?? call.result ?? "",
                    tool_call_id: call.id
                )
            }
            return [assistant] + results
        }
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
