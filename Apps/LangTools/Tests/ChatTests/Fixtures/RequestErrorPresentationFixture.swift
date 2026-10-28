import Foundation
import SwiftUI
import Chat
import LangTools
@testable import ChatUI

/// Shared by the macOS test and dedicated iOS host, never the ordinary app.
/// Uses ChatUI's real composer and error handler, not a replica of its alert.
/// Debug testability permits internal UI access; no submodule changes or trust
/// bypass are required. No real message, settings, credential or network service
/// is constructed, even if a composer control is accidentally activated.
@MainActor
final class RequestErrorPresentationFixture {
    private let service = InertRequestErrorService()
    private let composer: MessageComposerView.ViewModel

    init() {
        composer = MessageComposerView.ViewModel(messageService: service)
    }

    var view: some View { MessageComposerView(viewModel: composer) }
    var isPresented: Bool { composer.showAlert }
    var mappingCount: Int { service.mappingCount }
    var unexpectedOperationCount: Int { service.unexpectedOperationCount }

    func presentToolLimit() {
        composer.handleError(LangToolsRequestError.toolIterationLimitReached)
    }
}

private final class InertRequestErrorService: ChatMessageService, @unchecked Sendable {
    private let lock = NSLock()
    private var mappings = 0
    private var unexpectedOperations = 0
    var chatMessages: [InertRequestErrorMessage] { [] }
    var mappingCount: Int { lock.lock(); defer { lock.unlock() }; return mappings }
    var unexpectedOperationCount: Int { lock.lock(); defer { lock.unlock() }; return unexpectedOperations }

    func handleError(error: any Error) -> ChatAlertInfo? {
        guard let requestError = error as? LangToolsRequestError else {
            preconditionFailure("Unexpected fixture error type")
        }
        lock.lock(); mappings += 1; lock.unlock()
        return requestError.chatAlertInfo
    }

    func send(message: String, stream: Bool) async throws {
        recordUnexpectedOperation()
        throw FixtureError.unexpectedSend
    }

    func deleteMessage(id: UUID) { recordUnexpectedOperation() }

    private func recordUnexpectedOperation() {
        lock.lock(); unexpectedOperations += 1; lock.unlock()
    }

    private enum FixtureError: Error { case unexpectedSend }
}

/// Required associated type only; the service always returns an empty array.
private final class InertRequestErrorMessage: ChatMessageInfo, @unchecked Sendable {
    let uuid = UUID()
    var id: UUID { uuid }
    let text: String? = nil
    let childChatMessages: [InertRequestErrorMessage] = []
    let isUser = false
    let isAssistant = false
    let isAgentEvent = false
    static func == (lhs: InertRequestErrorMessage, rhs: InertRequestErrorMessage) -> Bool { lhs.uuid == rhs.uuid }
    func hash(into hasher: inout Hasher) { hasher.combine(uuid) }
}
