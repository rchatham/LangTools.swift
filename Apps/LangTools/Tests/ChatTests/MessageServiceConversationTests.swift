import Agents
import ChatUI
import Foundation
import LangTools
import OpenAI
import XCTest
@testable import Chat

@MainActor
final class MessageServiceConversationTests: XCTestCase {
    func testSendsReuseConversationAndClearRotatesBeforeCleanup() async throws {
        let client = ConversationNetworkStub()
        let service = MessageService(networkClient: client)

        try await service.send(message: "first")
        try await service.send(message: "second")
        XCTAssertEqual(client.conversationIDs.count, 2)
        XCTAssertEqual(Set(client.conversationIDs).count, 1)
        let oldID = try XCTUnwrap(client.conversationIDs.first)

        service.clearMessages()
        try await service.send(message: "after clear")
        let newID = try XCTUnwrap(client.conversationIDs.last)
        XCTAssertNotEqual(newID, oldID)

        for _ in 0..<100 where client.endedConversationIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(client.endedConversationIDs, [oldID])
    }

    func testClearCancelsAndDrainsAllOldSendsBeforeEndingConversation() async throws {
        let client = DelayedConversationNetworkStub()
        let service = MessageService(networkClient: client)
        let firstOldSend = Task { try await service.send(message: "old-1") }
        let secondOldSend = Task { try await service.send(message: "old-2") }

        for _ in 0..<100 where client.delayedResponseCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(client.delayedResponseCount, 2)
        let oldID = try XCTUnwrap(client.conversationIDs.first)

        service.clearMessages()
        try await service.send(message: "fresh")
        XCTAssertEqual(service.messages.count, 2)

        for oldSend in [firstOldSend, secondOldSend] {
            do {
                try await oldSend.value
                XCTFail("Expected the old conversation send to be cancelled")
            } catch is CancellationError {
                // Expected.
            }
        }
        for _ in 0..<100 where client.endedConversationIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(client.endedConversationIDs, [oldID])
        XCTAssertEqual(client.terminationCountObservedAtEnd, 2)
        XCTAssertEqual(service.messages.map(\.text), ["fresh", "fresh-response"])
    }

    func testFailedFollowupPreservesCompletedToolEvents() async {
        let client = ToolEventNetworkStub(completesTool: true)
        let service = MessageService(networkClient: client)

        do {
            try await service.send(message: "use a tool")
            XCTFail("Expected the follow-up to fail")
        } catch is ToolFollowupError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let assistant = service.messages.first(where: { $0.isAssistant })
        XCTAssertEqual(assistant?.toolCalls.count, 1)
        XCTAssertEqual(assistant?.toolCalls.first?.status, .success)
        XCTAssertEqual(assistant?.toolCalls.first?.result, "completed result")
    }

    func testFailedFollowupMarksIncompleteToolCallFailed() async {
        let client = ToolEventNetworkStub(completesTool: false)
        let service = MessageService(networkClient: client)

        do {
            try await service.send(message: "use a tool")
            XCTFail("Expected the follow-up to fail")
        } catch is ToolFollowupError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let call = service.messages.first(where: { $0.isAssistant })?.toolCalls.first
        XCTAssertEqual(call?.status, .failure)
        XCTAssertEqual(call?.result, "The tool follow-up failed.")
    }

    func testSuccessfulStreamMarksIncompleteToolCallFailed() async throws {
        let client = ToolEventNetworkStub(completesTool: false, finishError: nil)
        let service = MessageService(networkClient: client)

        try await service.send(message: "use a tool")

        let call = service.messages.first(where: { $0.isAssistant })?.toolCalls.first
        XCTAssertEqual(call?.status, .failure)
        XCTAssertEqual(call?.result, "Tool call ended without a completion result.")
    }

    func testCompletionWithoutResultPreservesItsImmediateFailureOnEarlierSplitMessage() async {
        let client = ToolEventNetworkStub(
            completesTool: false,
            emitsCompletionWithoutResult: true,
            responseBeforeFinish: "partial follow-up"
        )
        let service = MessageService(networkClient: client)

        do {
            try await service.send(message: "use a tool")
            XCTFail("Expected the follow-up to fail")
        } catch is ToolFollowupError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let call = service.messages.flatMap(\.toolCalls).first
        XCTAssertEqual(call?.status, .failure)
        XCTAssertEqual(call?.result, "Tool call ended without a completion result.")
        XCTAssertTrue(service.messages.contains(where: { $0.text == "partial follow-up" }))
    }

    func testConcurrentSendsRouteToolEventsToSeparateMessages() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let first = Task { try await service.send(message: "first") }
        let second = Task { try await service.send(message: "second") }

        for _ in 0..<100 where client.registeredRequestCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(client.registeredRequestCount, 2)

        client.emitToolEvents(for: "second", toolName: "second_tool", result: "second result")
        client.emitToolEvents(for: "first", toolName: "first_tool", result: "first result")
        client.finishRequest(for: "second", response: "second response")
        client.finishRequest(for: "first", response: "first response")

        try await first.value
        try await second.value

        let toolMessages = service.messages.filter { !$0.toolCalls.isEmpty }
        XCTAssertEqual(toolMessages.count, 2)
        XCTAssertTrue(toolMessages.allSatisfy { $0.toolCalls.count == 1 })
        XCTAssertEqual(Set(toolMessages.compactMap { $0.toolCalls.first?.name }), ["first_tool", "second_tool"])
        XCTAssertEqual(Set(toolMessages.compactMap { $0.toolCalls.first?.result }), ["first result", "second result"])
        assertToolMessage(before: "first response", hasName: "first_tool", result: "first result", in: service.messages)
        assertToolMessage(before: "second response", hasName: "second_tool", result: "second result", in: service.messages)
    }

    func testOrphanCompletionDoesNotAttachToAnotherConcurrentSendsToolAnchor() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let first = Task { try await service.send(message: "first orphan") }
        let second = Task { try await service.send(message: "second tool") }

        for _ in 0..<100 where client.registeredRequestCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: "first orphan", toolName: "removed_tool", selectionID: "first-id")
        for _ in 0..<100 where !service.messages.flatMap(\.toolCalls).contains(where: { $0.name == "removed_tool" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let removedAnchorID = try XCTUnwrap(
            service.messages.first(where: { $0.toolCalls.contains(where: { $0.name == "removed_tool" }) })?.uuid
        )
        service.messages.removeAll(where: { $0.uuid == removedAnchorID })

        client.yieldResponse("first ", for: "first orphan")
        for _ in 0..<100 where !service.messages.contains(where: { $0.text == "first " }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let firstTextID = try XCTUnwrap(service.messages.first(where: { $0.text == "first " })?.uuid)

        client.emitToolCalled(for: "second tool", toolName: "other_tool", selectionID: "second-id")
        for _ in 0..<100 where !service.messages.flatMap(\.toolCalls).contains(where: { $0.name == "other_tool" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let otherAnchorID = try XCTUnwrap(
            service.messages.first(where: { $0.toolCalls.contains(where: { $0.name == "other_tool" }) })?.uuid
        )

        client.emitToolCompleted(
            for: "first orphan",
            result: "orphan result",
            selectionID: "first-id"
        )
        for _ in 0..<100 where !service.messages.flatMap(\.toolCalls).contains(where: { $0.result == "orphan result" }) {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(
            service.messages.first(where: { $0.uuid == otherAnchorID })?.toolCalls.map(\.name),
            ["other_tool"]
        )
        let orphanAnchor = try XCTUnwrap(
            service.messages.first(where: { $0.toolCalls.contains(where: { $0.result == "orphan result" }) })
        )
        XCTAssertNotEqual(orphanAnchor.uuid, otherAnchorID)
        XCTAssertNotEqual(orphanAnchor.uuid, firstTextID)

        client.yieldResponse("continued", for: "first orphan")
        client.emitToolCompleted(for: "second tool", result: "other result", selectionID: "second-id")
        client.finishRequest(for: "first orphan")
        client.finishRequest(for: "second tool")
        try await first.value
        try await second.value

        XCTAssertEqual(service.messages.first(where: { $0.uuid == firstTextID })?.text, "first continued")
    }

    func testToolStartIsVisibleBeforeAnyResponseChunk() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "pending") }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: "pending", toolName: "slow_tool")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        let call = try XCTUnwrap(service.messages.flatMap(\.toolCalls).first)
        XCTAssertEqual(call.name, "slow_tool")
        XCTAssertEqual(call.status, .pending)
        XCTAssertNil(call.result)
        XCTAssertEqual(service.bufferedEventCountForTesting, 0)

        client.finishRequest(for: "pending")
        try await send.value
    }

    func testToolCompletionUpdatesVisibleCallBeforeAnyResponseChunk() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "success") }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: "success", toolName: "slow_tool")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).first?.status != .pending {
            try await Task.sleep(for: .milliseconds(5))
        }
        let callID = try XCTUnwrap(service.messages.flatMap(\.toolCalls).first?.id)

        client.emitToolCompleted(for: "success", result: "done")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).first?.status != .success {
            try await Task.sleep(for: .milliseconds(5))
        }

        let call = try XCTUnwrap(service.messages.flatMap(\.toolCalls).first)
        XCTAssertEqual(call.id, callID)
        XCTAssertEqual(call.result, "done")
        XCTAssertEqual(service.bufferedEventCountForTesting, 0)

        client.finishRequest(for: "success")
        try await send.value
    }

    func testToolFailureUpdatesVisibleCallBeforeAnyResponseChunk() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "failure") }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: "failure", toolName: "fragile_tool")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).first?.status != .pending {
            try await Task.sleep(for: .milliseconds(5))
        }
        let callID = try XCTUnwrap(service.messages.flatMap(\.toolCalls).first?.id)

        client.emitToolCompleted(for: "failure", result: "boom", isError: true)
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).first?.status != .failure {
            try await Task.sleep(for: .milliseconds(5))
        }

        let call = try XCTUnwrap(service.messages.flatMap(\.toolCalls).first)
        XCTAssertEqual(call.id, callID)
        XCTAssertEqual(call.result, "boom")
        XCTAssertEqual(service.bufferedEventCountForTesting, 0)

        client.finishRequest(for: "failure")
        try await send.value
    }

    func testToolCompletionUpdatesOriginalCardAfterResponseAnchorChanges() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "interleaved") }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: "interleaved", toolName: "slow_tool", selectionID: "provider-call")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        let originalAnchor = try XCTUnwrap(service.messages.first(where: { !$0.toolCalls.isEmpty }))
        let originalAnchorID = originalAnchor.uuid
        let originalCall = try XCTUnwrap(originalAnchor.toolCalls.first)
        let originalCallID = originalCall.id
        XCTAssertEqual(originalCall.status, .pending)
        XCTAssertNil(originalCall.result)

        client.yieldResponse("parent output", for: "interleaved")
        for _ in 0..<100 where !service.messages.contains(where: { $0.text == "parent output" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let parentOutputIndex = try XCTUnwrap(service.messages.firstIndex(where: { $0.text == "parent output" }))

        client.emitToolCompleted(for: "interleaved", result: "tool result", selectionID: "provider-call")
        client.finishRequest(for: "interleaved")
        try await send.value

        let calls = service.messages.flatMap(\.toolCalls)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, originalCallID)
        XCTAssertEqual(calls[0].status, .success)
        XCTAssertEqual(calls[0].result, "tool result")

        let finalAnchorIndex = try XCTUnwrap(service.messages.firstIndex(where: { $0.uuid == originalAnchorID }))
        XCTAssertEqual(service.messages[finalAnchorIndex].uuid, originalAnchorID)
        XCTAssertLessThan(finalAnchorIndex, parentOutputIndex)
    }

    func testEarlierToolCompletionDoesNotSplitNewerStreamedTextAnchor() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "completion between chunks") }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(
            for: "completion between chunks",
            toolName: "slow_tool",
            selectionID: "provider-call"
        )
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.yieldResponse("first ", for: "completion between chunks")
        for _ in 0..<100 where !service.messages.contains(where: { $0.text == "first " }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let textAnchorID = try XCTUnwrap(
            service.messages.first(where: { $0.text == "first " })?.uuid
        )

        client.emitToolCompleted(
            for: "completion between chunks",
            result: "tool result",
            selectionID: "provider-call"
        )
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).first?.status != .success {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.yieldResponse("second", for: "completion between chunks")
        client.finishRequest(for: "completion between chunks")
        try await send.value

        let textMessages = service.messages.filter { $0.isAssistant && $0.isStringContent }
        XCTAssertEqual(textMessages.count, 1)
        XCTAssertEqual(textMessages.first?.uuid, textAnchorID)
        XCTAssertEqual(textMessages.first?.text, "first second")
    }

    func testIDLessToolCompletionsUpdateOriginalCardsInFIFOOrderAfterResponseAnchorChanges() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "id-less interleaved") }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitIDLessToolCalled(for: "id-less interleaved", toolName: "first_tool")
        client.emitIDLessToolCalled(for: "id-less interleaved", toolName: "second_tool")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let originalAnchor = try XCTUnwrap(service.messages.first(where: { !$0.toolCalls.isEmpty }))
        let originalAnchorID = originalAnchor.uuid
        let originalCalls = originalAnchor.toolCalls
        XCTAssertEqual(originalCalls.count, 2)
        XCTAssertEqual(originalCalls.map(\.status), [.pending, .pending])

        client.yieldResponse("parent output", for: "id-less interleaved")
        for _ in 0..<100 where !service.messages.contains(where: { $0.text == "parent output" }) {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.emitToolCompleted(for: "id-less interleaved", result: "first result", selectionID: "")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).first?.status != .success {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCompleted(for: "id-less interleaved", result: "second result", selectionID: "")
        client.finishRequest(for: "id-less interleaved")
        try await send.value

        let completedCalls = service.messages.flatMap(\.toolCalls)
        XCTAssertEqual(completedCalls.map(\.id), originalCalls.map(\.id))
        XCTAssertEqual(completedCalls.map(\.name), ["first_tool", "second_tool"])
        XCTAssertEqual(completedCalls.map(\.status), [.success, .success])
        XCTAssertEqual(completedCalls.map(\.result), ["first result", "second result"])
        XCTAssertEqual(
            service.messages.first(where: { !$0.toolCalls.isEmpty })?.uuid,
            originalAnchorID
        )
    }

    func testCompletionWithoutResultImmediatelyFailsEarliestPendingCallWithoutSplittingText() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let request = "missing completion result"
        let send = Task { try await service.send(message: request) }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: request, toolName: "first_tool", selectionID: "first")
        client.emitIDLessToolCalled(for: request, toolName: "second_tool")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.yieldResponse("first ", for: request)
        for _ in 0..<100 where !service.messages.contains(where: { $0.text == "first " }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let textAnchorID = try XCTUnwrap(service.messages.first(where: { $0.text == "first " })?.uuid)

        client.emitToolCompletedWithoutResult(for: request)
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).first?.status != .failure {
            try await Task.sleep(for: .milliseconds(5))
        }

        var calls = service.messages.flatMap(\.toolCalls)
        XCTAssertEqual(calls[0].status, .failure)
        XCTAssertEqual(calls[0].result, "Tool call ended without a completion result.")
        XCTAssertEqual(calls[1].status, .pending)
        XCTAssertNil(calls[1].result)

        client.emitToolCompleted(for: request, result: "second result", selectionID: "")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls)[1].status != .success {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.yieldResponse("second", for: request)
        client.finishRequest(for: request)
        try await send.value

        calls = service.messages.flatMap(\.toolCalls)
        XCTAssertEqual(calls[1].status, .success)
        XCTAssertEqual(calls[1].result, "second result")
        let textMessages = service.messages.filter { $0.isAssistant && $0.isStringContent }
        XCTAssertEqual(textMessages.count, 1)
        XCTAssertEqual(textMessages.first?.uuid, textAnchorID)
        XCTAssertEqual(textMessages.first?.text, "first second")
    }

    func testEmptyCompletionsPreferIDLessCallsThenMatchIdentifiedCallsInFIFOOrder() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let request = "empty completion mixed queue"
        let send = Task { try await service.send(message: request) }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: request, toolName: "first_identified", selectionID: "first")
        client.emitIDLessToolCalled(for: request, toolName: "id_less")
        client.emitToolCalled(for: request, toolName: "second_identified", selectionID: "second")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.emitToolCompleted(for: request, result: "id-less result", selectionID: "")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls)[1].status != .success {
            try await Task.sleep(for: .milliseconds(5))
        }
        var calls = service.messages.flatMap(\.toolCalls)
        XCTAssertEqual(calls.map(\.status), [.pending, .success, .pending])
        XCTAssertEqual(calls[1].result, "id-less result")

        client.emitToolCompleted(for: request, result: "first result", selectionID: "")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls)[0].status != .success {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCompleted(for: request, result: "second result", selectionID: "")
        client.finishRequest(for: request)
        try await send.value

        calls = service.messages.flatMap(\.toolCalls)
        XCTAssertEqual(calls.map(\.status), [.success, .success, .success])
        XCTAssertEqual(calls.map(\.result), ["first result", "id-less result", "second result"])
    }

    func testUnmatchedIdentifiedCompletionDoesNotConsumeIDLessPendingCall() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "mixed selection ids") }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitIDLessToolCalled(for: "mixed selection ids", toolName: "id_less_tool")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let idLessCallID = try XCTUnwrap(service.messages.flatMap(\.toolCalls).first?.id)

        client.emitToolCompleted(
            for: "mixed selection ids",
            result: "identified orphan",
            selectionID: "unknown-id"
        )
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        var calls = service.messages.flatMap(\.toolCalls)
        let idLessCall = try XCTUnwrap(calls.first(where: { $0.id == idLessCallID }))
        XCTAssertEqual(idLessCall.status, .pending)
        XCTAssertNil(idLessCall.result)
        XCTAssertEqual(calls.first(where: { $0.id != idLessCallID })?.result, "identified orphan")

        client.emitToolCompleted(for: "mixed selection ids", result: "id-less result", selectionID: "")
        client.finishRequest(for: "mixed selection ids")
        try await send.value

        calls = service.messages.flatMap(\.toolCalls)
        XCTAssertEqual(calls.first(where: { $0.id == idLessCallID })?.status, .success)
        XCTAssertEqual(calls.first(where: { $0.id == idLessCallID })?.result, "id-less result")
        XCTAssertEqual(calls.first(where: { $0.id != idLessCallID })?.result, "identified orphan")
    }

    func testBackToBackToolCallbacksPublishPendingBeforeSuccess() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        var observedStatuses: [ChatToolCall.Status] = []
        service.messageUpdatedCallback = { message in
            if let call = message.toolCalls.first(where: { $0.name == "immediate_tool" }) {
                observedStatuses.append(call.status)
            }
        }
        let send = Task { try await service.send(message: "back-to-back") }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolEvents(
            for: "back-to-back",
            toolName: "immediate_tool",
            result: "immediate result"
        )
        client.finishRequest(for: "back-to-back")
        try await send.value

        XCTAssertEqual(observedStatuses, [.pending, .success])
        let call = try XCTUnwrap(service.messages.flatMap(\.toolCalls).first)
        XCTAssertEqual(call.status, .success)
        XCTAssertEqual(call.result, "immediate result")
    }

    func testUnresolvableTrackedCompletionDoesNotConsumeAnotherPendingCall() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "missing tracked call") }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: "missing tracked call", toolName: "removed_tool", selectionID: "tracked")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let originalAnchorID = try XCTUnwrap(service.messages.first(where: { !$0.toolCalls.isEmpty })?.uuid)

        client.yieldResponse("parent output", for: "missing tracked call")
        for _ in 0..<100 where !service.messages.contains(where: { $0.text == "parent output" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: "missing tracked call", toolName: "remaining_tool", selectionID: "tracked")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let remainingCallID = try XCTUnwrap(
            service.messages.first(where: { $0.text == "parent output" })?.toolCalls.first?.id
        )
        service.messages.removeAll(where: { $0.uuid == originalAnchorID })

        client.emitToolCompleted(for: "missing tracked call", result: "orphan result", selectionID: "tracked")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let remainingPendingCall = try XCTUnwrap(
            service.messages.flatMap(\.toolCalls).first(where: { $0.id == remainingCallID })
        )
        XCTAssertEqual(remainingPendingCall.status, .pending)
        XCTAssertNil(remainingPendingCall.result)

        client.emitToolCompleted(for: "missing tracked call", result: "remaining result", selectionID: "tracked")
        client.finishRequest(for: "missing tracked call")
        try await send.value

        let calls = try XCTUnwrap(
            service.messages.first(where: { $0.text == "parent output" })?.toolCalls
        )
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first(where: { $0.id == remainingCallID })?.status, .success)
        XCTAssertEqual(calls.first(where: { $0.id == remainingCallID })?.result, "remaining result")
        XCTAssertEqual(calls.first(where: { $0.id != remainingCallID })?.status, .success)
        XCTAssertEqual(calls.first(where: { $0.id != remainingCallID })?.result, "orphan result")
        XCTAssertEqual(service.messages.filter { !$0.toolCalls.isEmpty }.count, 1)
    }

    func testRemovedOnlyToolAnchorPlacesOrphanBeforeLiveTextWithoutSplittingStream() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let request = "removed only anchor"
        let send = Task { try await service.send(message: request) }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: request, toolName: "removed_tool", selectionID: "tracked")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let removedAnchorID = try XCTUnwrap(service.messages.first(where: { !$0.toolCalls.isEmpty })?.uuid)

        client.yieldResponse("first ", for: request)
        for _ in 0..<100 where !service.messages.contains(where: { $0.text == "first " }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let textAnchorID = try XCTUnwrap(service.messages.first(where: { $0.text == "first " })?.uuid)
        service.messages.removeAll(where: { $0.uuid == removedAnchorID })

        client.emitToolCompleted(for: request, result: "orphan result", selectionID: "tracked")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.yieldResponse("second", for: request)
        client.finishRequest(for: request)
        try await send.value

        let orphanIndex = try XCTUnwrap(service.messages.firstIndex(where: { !$0.toolCalls.isEmpty }))
        let textIndex = try XCTUnwrap(service.messages.firstIndex(where: { $0.uuid == textAnchorID }))
        XCTAssertLessThan(orphanIndex, textIndex)
        XCTAssertEqual(service.messages[orphanIndex].toolCalls.first?.result, "orphan result")
        XCTAssertEqual(service.messages[textIndex].text, "first second")
        XCTAssertTrue(service.messages[textIndex].toolCalls.isEmpty)
    }

    func testRepeatedProviderSelectionIDsCompleteCallsInFIFOOrder() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "repeated") }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: "repeated", toolName: "first_tool", selectionID: "ollama")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).count < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: "repeated", toolName: "second_tool", selectionID: "ollama")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let originalCalls = service.messages.flatMap(\.toolCalls)
        XCTAssertEqual(originalCalls.count, 2)
        XCTAssertNotEqual(originalCalls[0].id, originalCalls[1].id)

        client.emitToolCompleted(for: "repeated", result: "first result", selectionID: "ollama")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).first?.status != .success {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCompleted(for: "repeated", result: "second result", selectionID: "ollama")
        client.finishRequest(for: "repeated")
        try await send.value

        let completedCalls = service.messages.flatMap(\.toolCalls)
        XCTAssertEqual(completedCalls.count, 2)
        XCTAssertEqual(completedCalls.map(\.id), originalCalls.map(\.id))
        XCTAssertEqual(completedCalls.map(\.name), ["first_tool", "second_tool"])
        XCTAssertEqual(completedCalls.map(\.status), [.success, .success])
        XCTAssertEqual(completedCalls.map(\.result), ["first result", "second result"])
    }

    func testToolActivityPrecedesCombinedStreamedParentOutput() async throws {
        let client = ControlledToolEventNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "ordered") }

        for _ in 0..<100 where client.registeredRequestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCalled(for: "ordered", toolName: "ordered_tool")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.emitToolCompleted(for: "ordered", result: "tool result")
        for _ in 0..<100 where service.messages.flatMap(\.toolCalls).first?.status != .success {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.yieldResponse("parent ", for: "ordered")
        client.yieldResponse("output", for: "ordered")
        client.finishRequest(for: "ordered")
        try await send.value

        let toolMessageIndices = service.messages.indices.filter { !service.messages[$0].toolCalls.isEmpty }
        let parentIndices = service.messages.indices.filter { service.messages[$0].text == "parent output" }
        XCTAssertEqual(toolMessageIndices.count, 1)
        XCTAssertEqual(parentIndices.count, 1)
        XCTAssertLessThan(try XCTUnwrap(toolMessageIndices.first), try XCTUnwrap(parentIndices.first))
        XCTAssertEqual(service.messages.flatMap(\.toolCalls).map(\.name), ["ordered_tool"])
    }

    private func assertToolMessage(before response: String, hasName name: String, result: String, in messages: [Message], file: StaticString = #filePath, line: UInt = #line) {
        guard let responseIndex = messages.firstIndex(where: { $0.text == response }) else {
            XCTFail("Missing response \(response)", file: file, line: line)
            return
        }
        guard let toolIndex = messages.firstIndex(where: { message in
            message.toolCalls.contains { $0.name == name && $0.result == result }
        }) else {
            XCTFail("Missing tool call \(name)", file: file, line: line)
            return
        }
        XCTAssertLessThan(toolIndex, responseIndex, file: file, line: line)
    }

    func testOverlappingSendsKeepToolCallbacksAttachedToTheirRequestAndDiscardLateCallbacks() async throws {
        let client = OverlappingNetworkStub()
        let service = MessageService(networkClient: client)

        let firstSend = Task { try await service.send(message: "first") }
        for _ in 0..<100 where client.requestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let secondSend = Task { try await service.send(message: "second") }
        for _ in 0..<100 where client.requestCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(client.requestCount, 2)

        client.yield("first-preamble", request: 0)
        client.yield("second-preamble", request: 1)
        for _ in 0..<100 where service.messages.filter(\.isAssistant).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.emitToolLifecycle(request: 0, name: "first_tool", result: "first-result")
        client.emitToolLifecycle(request: 1, name: "second_tool", result: "second-result")
        for _ in 0..<100 where service.messages.filter({ !$0.toolCalls.isEmpty }).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.finish(request: 1)
        client.finish(request: 0)
        try await firstSend.value
        try await secondSend.value

        let cardMessages = service.messages.filter { !$0.toolCalls.isEmpty }
        XCTAssertEqual(cardMessages.count, 2)
        XCTAssertEqual(cardMessages.flatMap(\.toolCalls).map(\.name).sorted(), ["first_tool", "second_tool"])
        for message in cardMessages {
            XCTAssertEqual(message.toolCalls.count, 1)
            let call = message.toolCalls[0]
            let isFirstRequest = call.name == "first_tool"
            XCTAssertEqual(call.result, isFirstRequest ? "first-result" : "second-result")
            XCTAssertEqual(message.text, isFirstRequest ? "first-preamble" : "second-preamble")
        }

        XCTAssertEqual(service.bufferedEventCountForTesting, 0)
        client.emitToolLifecycle(request: 0, name: "late_tool", result: "late-result")
        XCTAssertEqual(
            service.bufferedEventCountForTesting,
            0,
            "A completed send must reject callbacks instead of retaining them in its event buffer"
        )
    }

    func testClearingToolHistoryNotifiesPersistenceForAnchorMessage() async throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let client = OverlappingNetworkStub()
        let service = MessageService(networkClient: client)
        var persistedToolCallNames: [UUID: [String]] = [:]
        var persistedProviderResults: [UUID: [String: String]] = [:]
        service.messageUpdatedCallback = { message in
            persistedToolCallNames[message.uuid] = message.toolCalls.map(\.name)
            persistedProviderResults[message.uuid] = message.providerToolResults
        }

        let send = Task { try await service.send(message: "history") }
        for _ in 0..<100 where client.requestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(client.requestCount, 1)

        client.yield("preamble", request: 0)
        for _ in 0..<100 where service.messages.first(where: \.isAssistant) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let anchor = try XCTUnwrap(service.messages.first(where: \.isAssistant))
        anchor.providerToolResults = ["history_tool-id": "raw-result"]

        client.emitToolLifecycle(request: 0, name: "history_tool", result: "visible-result")
        for _ in 0..<100 where anchor.toolCalls.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(anchor.toolCalls.map(\.name), ["history_tool"], "Sanitizing persistence must not hide the live card")
        XCTAssertEqual(persistedToolCallNames[anchor.uuid], [])
        XCTAssertEqual(anchor.providerToolResults, [:])
        XCTAssertEqual(persistedProviderResults[anchor.uuid], [:])

        client.yield("follow-up", request: 0)
        client.finish(request: 0)
        try await send.value

        XCTAssertEqual(anchor.toolCalls, [])
        XCTAssertEqual(anchor.providerToolResults, [:])
        XCTAssertEqual(persistedToolCallNames[anchor.uuid], [])
        XCTAssertEqual(persistedProviderResults[anchor.uuid], [:])
    }

    func testHistoryDisabledClearsToolCardsWhenStreamFinishesWithoutFollowUp() async throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let client = OverlappingNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "no follow-up") }
        for _ in 0..<100 where client.requestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.yield("preamble", request: 0)
        for _ in 0..<100 where service.messages.first(where: \.isAssistant) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let anchor = try XCTUnwrap(service.messages.first(where: \.isAssistant))
        client.emitToolLifecycle(request: 0, name: "private_tool", result: "private-result")
        client.finish(request: 0)
        try await send.value

        XCTAssertEqual(anchor.text, "preamble")
        XCTAssertTrue(anchor.toolCalls.isEmpty)
        XCTAssertTrue(anchor.providerToolResults.isEmpty)
    }

    func testHistoryDisabledKeepsCardsLiveUntilTerminalSend() async throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let client = OverlappingNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "empty follow-up") }
        for _ in 0..<100 where client.requestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.emitToolLifecycle(request: 0, name: "private_tool", result: "private-result")
        for _ in 0..<100 where service.messages.first(where: { !$0.toolCalls.isEmpty }) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let anchor = try XCTUnwrap(service.messages.first(where: { !$0.toolCalls.isEmpty }))
        XCTAssertEqual(anchor.toolCalls.map(\.name), ["private_tool"])
        XCTAssertTrue(anchor.providerToolResults.isEmpty)

        client.finish(request: 0)
        try await send.value

        XCTAssertTrue(anchor.toolCalls.isEmpty)
        XCTAssertTrue(anchor.providerToolResults.isEmpty)
        XCTAssertEqual(service.messages.map(\.role), [.user])
        XCTAssertEqual(service.messages.map(\.text), ["empty follow-up"])
    }

    func testHistoryDisabledClearsLiveCardsWhenStreamThrows() async throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let client = OverlappingNetworkStub()
        let service = MessageService(networkClient: client)
        let send = Task { try await service.send(message: "error") }
        for _ in 0..<100 where client.requestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.emitToolLifecycle(request: 0, name: "private_tool", result: "private-result")
        for _ in 0..<100 where service.messages.first(where: { !$0.toolCalls.isEmpty }) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let anchor = try XCTUnwrap(service.messages.first(where: { !$0.toolCalls.isEmpty }))
        XCTAssertEqual(anchor.toolCalls.map(\.name), ["private_tool"])

        client.fail(request: 0)
        do {
            try await send.value
            XCTFail("Expected stream failure")
        } catch OverlappingStubError.failed {
            // Expected.
        }

        XCTAssertTrue(anchor.toolCalls.isEmpty)
        XCTAssertTrue(anchor.providerToolResults.isEmpty)
    }

    func testHistoryDisabledOverlappingSendSnapshotExcludesLiveToolCards() async throws {
        let previousKeepsToolCallsInHistory = ToolSettings.shared.keepsToolCallsInHistory
        ToolSettings.shared.keepsToolCallsInHistory = false
        defer { ToolSettings.shared.keepsToolCallsInHistory = previousKeepsToolCallsInHistory }

        let client = OverlappingNetworkStub()
        let service = MessageService(networkClient: client)
        let firstSend = Task { try await service.send(message: "first") }
        for _ in 0..<100 where client.requestCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }

        client.emitToolLifecycle(request: 0, name: "private_tool", result: "private-result")
        for _ in 0..<100 where service.messages.first(where: { !$0.toolCalls.isEmpty }) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let liveAnchor = try XCTUnwrap(service.messages.first(where: { !$0.toolCalls.isEmpty }))
        service.messages.append(
            .contentCards(
                ContentCardsContent(
                    cardType: "test-cards",
                    message: "cards summary",
                    cardsJSON: "[]",
                    cardCount: 0
                )
            )
        )

        let secondSend = Task { try await service.send(message: "second") }
        for _ in 0..<100 where client.requestCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(liveAnchor.toolCalls.map(\.name), ["private_tool"], "Taking a request snapshot must not hide the live card")
        XCTAssertTrue(client.toolCallNamesSent(request: 1).isEmpty)
        XCTAssertTrue(client.providerToolResultsSent(request: 1).isEmpty)
        XCTAssertEqual(client.messageRolesSent(request: 1), [.system, .user, .assistant, .user])
        XCTAssertEqual(
            Array(client.messageTextsSent(request: 1).suffix(3)),
            ["first", "cards summary", "second"],
            "The empty tool anchor must be omitted while content-card messages remain in the request"
        )
        guard case .contentCards = client.messageContentTypesSent(request: 1)[2] else {
            return XCTFail("Expected the content-card message to retain its semantic content type")
        }

        client.finish(request: 1)
        client.finish(request: 0)
        try await secondSend.value
        try await firstSend.value
        XCTAssertTrue(liveAnchor.toolCalls.isEmpty)
    }

    func testLegacyNetworkClientUsesCompatibilityPath() async throws {
        let client = LegacyNetworkStub()
        let service = MessageService(networkClient: client)

        try await service.send(message: "legacy")

        XCTAssertEqual(client.streamRequestCount, 1)
    }
}

private final class OverlappingNetworkStub: NetworkClientProtocol, @unchecked Sendable {
    static let shared: NetworkClientProtocol = OverlappingNetworkStub()

    private struct Request {
        let eventHandler: (LangToolsToolEvent) -> Void
        let continuation: AsyncThrowingStream<String, Error>.Continuation
        let toolCallNames: [String]
        let providerToolResults: [String: String]
        let messageRoles: [Role]
        let messageTexts: [String?]
        let messageContentTypes: [ContentType]
    }

    private let lock = NSLock()
    private var requests: [Request] = []

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    func emitToolLifecycle(request index: Int, name: String, result: String) {
        let handler = lock.withLock { requests[index].eventHandler }
        let id = "\(name)-id"
        handler(.toolCalled(OverlapSelection(id: id, name: name, arguments: "{}")))
        handler(.toolCompleted(OverlapResult(tool_selection_id: id, result: result)))
    }

    func yield(_ chunk: String, request index: Int) {
        let continuation = lock.withLock { requests[index].continuation }
        continuation.yield(chunk)
    }

    func finish(request index: Int) {
        let continuation = lock.withLock { requests[index].continuation }
        continuation.finish()
    }

    func fail(request index: Int) {
        let continuation = lock.withLock { requests[index].continuation }
        continuation.finish(throwing: OverlappingStubError.failed)
    }

    func toolCallNamesSent(request index: Int) -> [String] {
        lock.withLock { requests[index].toolCallNames }
    }

    func providerToolResultsSent(request index: Int) -> [String: String] {
        lock.withLock { requests[index].providerToolResults }
    }

    func messageRolesSent(request index: Int) -> [Role] {
        lock.withLock { requests[index].messageRoles }
    }

    func messageTextsSent(request index: Int) -> [String?] {
        lock.withLock { requests[index].messageTexts }
    }

    func messageContentTypesSent(request index: Int) -> [ContentType] {
        lock.withLock { requests[index].messageContentTypes }
    }

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message {
        throw NetworkClient.NetworkError.incompatibleRequest
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        let toolCallNames = messages.flatMap { $0.toolCalls.map(\.name) }
        let providerToolResults = messages.reduce(into: [String: String]()) { results, message in
            results.merge(message.providerToolResults) { _, latest in latest }
        }
        return AsyncThrowingStream { continuation in
            lock.withLock {
                requests.append(
                    Request(
                        eventHandler: toolEventHandler,
                        continuation: continuation,
                        toolCallNames: toolCallNames,
                        providerToolResults: providerToolResults,
                        messageRoles: messages.map(\.role),
                        messageTexts: messages.map(\.text),
                        messageContentTypes: messages.map(\.contentType)
                    )
                )
            }
        }
    }

    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw NetworkClient.NetworkError.incompatibleRequest }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}

private enum OverlappingStubError: Error {
    case failed
}

private struct OverlapSelection: LangToolsToolSelection {
    let id: String?
    let name: String?
    let arguments: String
}

private struct OverlapResult: LangToolsToolSelectionResult {
    let tool_selection_id: String
    let result: String
    let is_error: Bool

    init(tool_selection_id: String, result: String, is_error: Bool) {
        self.tool_selection_id = tool_selection_id
        self.result = result
        self.is_error = is_error
    }

    init(tool_selection_id: String, result: String) {
        self.init(tool_selection_id: tool_selection_id, result: result, is_error: false)
    }
}

private final class ConversationNetworkStub: ConversationAwareNetworkClientProtocol {
    static let shared: NetworkClientProtocol = ConversationNetworkStub()
    private(set) var conversationIDs: [UUID] = []
    private(set) var endedConversationIDs: [UUID] = []

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message {
        Message(text: "legacy", role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("legacy")
            continuation.finish()
        }
    }

    func performChatCompletionRequest(messages: [Message], model: Model, conversationID: UUID, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message {
        conversationIDs.append(conversationID)
        return Message(text: "response", role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, conversationID: UUID, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        conversationIDs.append(conversationID)
        return AsyncThrowingStream { continuation in
            continuation.yield("response")
            continuation.finish()
        }
    }

    func endConversation(id: UUID) async { endedConversationIDs.append(id) }
    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw NetworkClient.NetworkError.incompatibleRequest }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}

private final class DelayedConversationNetworkStub: ConversationAwareNetworkClientProtocol, @unchecked Sendable {
    static let shared: NetworkClientProtocol = DelayedConversationNetworkStub()
    private let lock = NSLock()
    private var delayedContinuations: [AsyncThrowingStream<String, Error>.Continuation] = []
    private var streamCount = 0
    private var terminatedStreamCount = 0
    private(set) var conversationIDs: [UUID] = []
    private(set) var endedConversationIDs: [UUID] = []
    private(set) var terminationCountObservedAtEnd = 0
    var delayedResponseCount: Int { delayedContinuations.count }

    func streamChatCompletionRequest(messages: [Message], model: Model, conversationID: UUID, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        conversationIDs.append(conversationID)
        streamCount += 1
        if streamCount <= 2 {
            return AsyncThrowingStream { continuation in
                continuation.onTermination = { [weak self] _ in
                    self?.recordTermination()
                }
                delayedContinuations.append(continuation)
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("fresh-response")
            continuation.finish()
        }
    }

    private func recordTermination() {
        lock.withLock { terminatedStreamCount += 1 }
    }

    private func terminationCount() -> Int {
        lock.withLock { terminatedStreamCount }
    }

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message { Message(text: "legacy", role: .assistant) }
    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> { throw NetworkClient.NetworkError.incompatibleRequest }
    func performChatCompletionRequest(messages: [Message], model: Model, conversationID: UUID, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message { Message(text: "response", role: .assistant) }
    func endConversation(id: UUID) async {
        terminationCountObservedAtEnd = terminationCount()
        endedConversationIDs.append(id)
    }
    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw NetworkClient.NetworkError.incompatibleRequest }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}

private struct TestToolSelection: LangToolsToolSelection {
    let id: String?
    let name: String?
    let arguments: String
}

private struct TestToolResult: LangToolsToolSelectionResult {
    let tool_selection_id: String
    let result: String
    let is_error: Bool
}

private enum ToolFollowupError: LocalizedError {
    case failed

    var errorDescription: String? { "The tool follow-up failed." }
}

private final class ToolEventNetworkStub: NetworkClientProtocol {
    static let shared: NetworkClientProtocol = ToolEventNetworkStub(completesTool: true)
    private let completesTool: Bool
    private let emitsCompletionWithoutResult: Bool
    private let responseBeforeFinish: String?
    private let finishError: ToolFollowupError?

    init(
        completesTool: Bool,
        emitsCompletionWithoutResult: Bool = false,
        responseBeforeFinish: String? = nil,
        finishError: ToolFollowupError? = .failed
    ) {
        self.completesTool = completesTool
        self.emitsCompletionWithoutResult = emitsCompletionWithoutResult
        self.responseBeforeFinish = responseBeforeFinish
        self.finishError = finishError
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        toolEventHandler(.toolCalled(TestToolSelection(id: "call-1", name: "test_tool", arguments: "{}")))
        if completesTool {
            toolEventHandler(.toolCompleted(TestToolResult(tool_selection_id: "call-1", result: "completed result", is_error: false)))
        } else if emitsCompletionWithoutResult {
            toolEventHandler(.toolCompleted(nil))
        }
        return AsyncThrowingStream { continuation in
            if let responseBeforeFinish {
                continuation.yield(responseBeforeFinish)
            }
            if let finishError {
                continuation.finish(throwing: finishError)
            } else {
                continuation.finish()
            }
        }
    }

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message { throw ToolFollowupError.failed }
    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw NetworkClient.NetworkError.incompatibleRequest }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}

private final class ControlledToolEventNetworkStub: NetworkClientProtocol {
    static let shared: NetworkClientProtocol = ControlledToolEventNetworkStub()

    private struct Request {
        let continuation: AsyncThrowingStream<String, Error>.Continuation
        let toolEventHandler: (LangToolsToolEvent) -> Void
    }

    private var requests: [String: Request] = [:]
    var registeredRequestCount: Int { requests.count }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        let message = messages.last(where: { $0.isUser })?.text ?? ""
        return AsyncThrowingStream { continuation in
            requests[message] = Request(continuation: continuation, toolEventHandler: toolEventHandler)
        }
    }

    func emitToolCalled(for message: String, toolName: String, selectionID: String? = nil) {
        guard let request = requests[message] else {
            XCTFail("Missing request for \(message)")
            return
        }
        request.toolEventHandler(
            .toolCalled(
                TestToolSelection(
                    id: selectionID ?? message,
                    name: toolName,
                    arguments: "{}"
                )
            )
        )
    }

    func emitIDLessToolCalled(for message: String, toolName: String) {
        guard let request = requests[message] else {
            XCTFail("Missing request for \(message)")
            return
        }
        request.toolEventHandler(
            .toolCalled(
                TestToolSelection(
                    id: nil,
                    name: toolName,
                    arguments: "{}"
                )
            )
        )
    }

    func emitToolCompleted(
        for message: String,
        result: String,
        isError: Bool = false,
        selectionID: String? = nil
    ) {
        guard let request = requests[message] else {
            XCTFail("Missing request for \(message)")
            return
        }
        request.toolEventHandler(
            .toolCompleted(
                TestToolResult(
                    tool_selection_id: selectionID ?? message,
                    result: result,
                    is_error: isError
                )
            )
        )
    }

    func emitToolCompletedWithoutResult(for message: String) {
        guard let request = requests[message] else {
            XCTFail("Missing request for \(message)")
            return
        }
        request.toolEventHandler(.toolCompleted(nil))
    }

    func emitToolEvents(for message: String, toolName: String, result: String) {
        emitToolCalled(for: message, toolName: toolName)
        emitToolCompleted(for: message, result: result)
    }

    func yieldResponse(_ response: String, for message: String) {
        guard let request = requests[message] else {
            XCTFail("Missing request for \(message)")
            return
        }
        request.continuation.yield(response)
    }

    func finishRequest(for message: String, response: String? = nil) {
        guard let request = requests[message] else {
            XCTFail("Missing request for \(message)")
            return
        }
        if let response {
            request.continuation.yield(response)
        }
        request.continuation.finish()
    }

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message { Message(text: "response", role: .assistant) }
    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw NetworkClient.NetworkError.incompatibleRequest }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}

private final class LegacyNetworkStub: NetworkClientProtocol {
    static let shared: NetworkClientProtocol = LegacyNetworkStub()
    private(set) var streamRequestCount = 0

    func performChatCompletionRequest(messages: [Message], model: Model, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) async throws -> Message {
        Message(text: "legacy", role: .assistant)
    }

    func streamChatCompletionRequest(messages: [Message], model: Model, stream: Bool, tools: [Tool]?, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> AsyncThrowingStream<String, Error> {
        streamRequestCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield("legacy")
            continuation.finish()
        }
    }

    func playAudio(for text: String) async throws {}
    func agentContext(messages: [Message], model: Model, eventHandler: @escaping (AgentEvent) -> Void) throws -> AgentContext { throw NetworkClient.NetworkError.incompatibleRequest }
    func updateApiKey(_ apiKey: String, for llm: APIService) throws {}
    func removeApiKey(for llm: APIService) throws {}
    func connectAccount(_ provider: AccountLoginProvider) async throws {}
    func disconnectAccount(_ provider: AccountLoginProvider) async throws {}
}
