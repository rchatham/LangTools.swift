import Foundation

/// Read/chat-only Codex routes shared by the loopback and capability-gated LAN servers.
/// Runtime injection exercises the real account actor without an installed/logged-in Codex CLI.
struct AccountRouteHandlers: Sendable {
    let runtime: CodexRuntimeService
    init(runtime: CodexRuntimeService = .shared) { self.runtime = runtime }

    func models() async throws -> HelperModelsResponse {
        HelperModelsResponse(models: try await runtime.modelSlugs())
    }

    func status() async throws -> HelperAuthStatusResponse {
        do {
            let status = try await runtime.accountStatus()
            return HelperAuthStatusResponse(provider: "openAI", authenticated: status.authenticated,
                accountIdentifier: status.accountIdentifier, expiresAt: nil,
                accessibleModelIDs: status.authenticated ? try await runtime.modelSlugs() : nil)
        } catch CodexAppServerError.unavailable {
            return Self.unauthenticatedStatus
        } catch CodexAppServerError.exited {
            return Self.unauthenticatedStatus
        }
    }

    private static var unauthenticatedStatus: HelperAuthStatusResponse {
        HelperAuthStatusResponse(provider: "openAI", authenticated: false, accountIdentifier: nil,
                                 expiresAt: nil, accessibleModelIDs: nil)
    }

    static func decodeChat(_ body: Data) throws -> HelperChatRequest {
        let payload = try JSONDecoder().decode(HelperChatRequest.self, from: body)
        guard payload.provider == "openAI" || payload.provider == "openai" else {
            throw CodexRuntimeError.badRequest("Only openAI is currently supported.")
        }
        let roles: Set<String> = ["system", "user", "assistant", "tool"]
        guard !payload.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.messages.isEmpty,
              payload.messages.allSatisfy({ roles.contains($0.role.lowercased()) }) else {
            throw CodexRuntimeError.badRequest("A model and valid chat messages are required.")
        }
        return payload
    }

    func chat(_ payload: HelperChatRequest, conversationID: UUID?) async throws -> HelperChatResponse {
        HelperChatResponse(content: try await runtime.chat(model: payload.model, messages: payload.messages,
                                                         conversationID: conversationID))
    }

    func endConversation(_ id: UUID) async { await runtime.endConversation(id: id) }

    func streamChat(_ payload: HelperChatRequest, conversationID: UUID?, sanitizeErrors: Bool = false,
                    send: @Sendable (Data) async throws -> Void) async throws {
        try await send(HTTPResponseEncoder.chunkedHeader(status: .ok))
        try await streamEvents(payload, conversationID: conversationID, sanitizeErrors: sanitizeErrors) {
            try await send(try HTTPResponseEncoder.ndjsonChunk($0))
        }
        try await send(HTTPResponseEncoder.terminalChunk)
    }

    func streamEvents(_ payload: HelperChatRequest, conversationID: UUID?, sanitizeErrors: Bool = false,
                      send: @Sendable (HelperChatStreamEvent) async throws -> Void) async throws {
        let cancellation = CodexChatStreamCancellation()
        // Install before the actor hop. Cancellation can precede producer creation
        // or occur while the returned handle is still queued for caller handoff.
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let handle = try await runtime.chatStreamHandle(
                model: payload.model, messages: payload.messages,
                conversationID: conversationID, cancellation: cancellation
            )
            do {
                try Task.checkCancellation()
                for try await event in handle.stream {
                    try Task.checkCancellation()
                    let wire: HelperChatStreamEvent
                    switch event {
                    case .delta(let value): wire = .delta(value)
                    case .complete(let value): wire = .complete(value)
                    }
                    try await send(wire)
                }
                await handle.wait()
                try Task.checkCancellation()
            } catch is CancellationError {
                await handle.cancelAndWait()
                guard !Task.isCancelled else { throw CancellationError() }
                try await send(.failure("Request cancelled."))
            } catch {
                await handle.cancelAndWait()
                try Task.checkCancellation()
                let message = sanitizeErrors ? "The helper could not complete this request." : error.localizedDescription
                try await send(.failure(message))
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
