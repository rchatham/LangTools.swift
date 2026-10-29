import Foundation
import XCTest
@testable import CLI

final class SessionContinuationTests: XCTestCase {
    private func withManager(_ body: (SessionManager, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(SessionManager(sessionsDirectory: directory.appendingPathComponent("sessions")), directory)
    }

    func testListAndPrefixLoadAreScopedToExactWorkingDirectory() throws {
        try withManager { manager, root in
            let repo = root.appendingPathComponent("repo").path
            let other = root.appendingPathComponent("repo-other").path
            let current = try manager.createSession(name: "here", workingDirectory: repo, model: "model")
            _ = try manager.createSession(name: "elsewhere", workingDirectory: other, model: "model")

            XCTAssertEqual(try manager.listSessions(in: repo).map(\.id), [current.id])
            XCTAssertEqual(try manager.session(matching: String(current.id.uuidString.prefix(8)), in: repo)?.id, current.id)
            XCTAssertNil(try manager.session(matching: current.id.uuidString, in: other))
            _ = try manager.createSession(name: "also-here", workingDirectory: repo, model: "model")
            XCTAssertThrowsError(try manager.session(matching: "", in: repo))
        }
    }

    func testSnapshotReplacesInsteadOfDuplicatingAndSurvivesReload() throws {
        try withManager { manager, root in
            let session = try manager.createSession(name: "continue", workingDirectory: root.path, model: "model")
            let user = Message(text: "first question", role: .user)
            let answer = Message(text: "first answer", role: .assistant)
            try manager.replaceMessages([user, answer])
            try manager.replaceMessages([user, answer, Message(text: "follow-up", role: .user)])

            let restored = try manager.loadSession(id: session.id)
            XCTAssertEqual(restored.messages.map(\.content), ["first question", "first answer", "follow-up"])
            XCTAssertEqual(restored.metadata.messageCount, 3)
            XCTAssertEqual(restored.messages.first?.id, user.uuid)
            XCTAssertEqual(restored.messages.map(\.role), [.user, .assistant, .user])
            XCTAssertEqual(restored.metadata.model, UserDefaults.model.rawValue)

            // A resumed turn must not replace the original IDs or timestamps.
            let resumed = manager.restoredMessages(from: restored)
            XCTAssertEqual(resumed.map(\.uuid), restored.messages.map(\.id))
            try manager.replaceMessages(resumed + [Message(text: "next answer", role: .assistant)])
            let continued = try manager.loadSession(id: session.id)
            XCTAssertEqual(continued.messages.map(\.content),
                           ["first question", "first answer", "follow-up", "next answer"])
            XCTAssertEqual(continued.messages.first?.timestamp, restored.messages.first?.timestamp)
            XCTAssertEqual(continued.messages.first?.id, restored.messages.first?.id)

            try manager.replaceMessages([])
            XCTAssertTrue(try manager.loadSession(id: session.id).messages.isEmpty)
        }
    }

    func testNoActiveSessionDoesNotCreateSnapshot() throws {
        try withManager { manager, root in
            try manager.replaceMessages([Message(text: "unsaved", role: .user)])
            XCTAssertTrue(try manager.listSessions(in: root.path).isEmpty)
        }
    }

    func testSessionDirectoryAndFilesRemainPrivateAcrossAtomicReplacement() throws {
        try withManager { manager, root in
            let sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
            XCTAssertEqual(try permissions(at: sessionsDirectory), 0o700)

            let session = try manager.createSession(
                name: "private",
                workingDirectory: root.path,
                model: "model"
            )
            let fileURL = sessionsDirectory.appendingPathComponent("\(session.id.uuidString).json")
            XCTAssertEqual(try permissions(at: fileURL), 0o600)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: sessionsDirectory.path
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: fileURL.path
            )

            try manager.saveSession(session)

            XCTAssertEqual(try permissions(at: sessionsDirectory), 0o700)
            XCTAssertEqual(try permissions(at: fileURL), 0o600)
        }
    }

    func testCreateSessionFailureDoesNotActivateUnsavedSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("blocking file".utf8).write(to: blockingFile)
        let invalidSessionsDirectory = blockingFile.appendingPathComponent("sessions")
        let manager = SessionManager(sessionsDirectory: invalidSessionsDirectory)
        let existingSessionID = UUID()
        manager.currentSessionId = existingSessionID

        XCTAssertThrowsError(try manager.createSession(
            name: "must-fail",
            workingDirectory: root.path,
            model: "model"
        ))
        XCTAssertEqual(manager.currentSessionId, existingSessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidSessionsDirectory.path))
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let value = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return value.intValue & 0o777
    }
}
