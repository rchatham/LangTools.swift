import XCTest
@testable import HelperCore

final class CodingWorkspaceAccessTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        temporary = temporary.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    private func directory(_ name: String) throws -> String {
        let url = temporary.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func expect(_ expected: CodingWorkspaceAccess.AccessError,
                        operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CodingWorkspaceAccess.AccessError, expected, file: file, line: line)
        }
    }

    func testDisabledByDefaultAndUnrelatedChatTokenDenied() async throws {
        let access = CodingWorkspaceAccess()
        await expect(.disabled) { _ = try await access.approvedRoots(credential: "chat-token") }
        await expect(.disabled) { _ = try await access.addRoot(path: self.temporary.path) }
        let token = try await access.enable()
        XCTAssertEqual(Data(base64Encoded: token)?.count, 32)
        await expect(.unauthorized) { _ = try await access.approvedRoots(credential: "chat-token") }
        await expect(.unauthorized) { _ = try await access.approvedRoots(credential: nil) }
        await expect(.unauthorized) { _ = try await access.approvedRoots(credential: "") }
    }

    func testCanonicalRootsAreDeduplicatedAndChildDirectoriesAllowed() async throws {
        let access = CodingWorkspaceAccess()
        let token = try await access.enable()
        let rootPath = try directory("project space 日本語")
        let child = try directory("project space 日本語/child")
        let root = try await access.addRoot(path: rootPath)
        let same = try await access.addRoot(path: child + "/..")
        XCTAssertEqual(root, same)
        let result = try await access.authorize(credential: token, rootID: root.id, directory: child)
        XCTAssertEqual(result, root.path + "/child")
        let roots = try await access.approvedRoots(credential: token)
        XCTAssertEqual(roots, [root])
    }

    func testPrefixCollisionTraversalAndSymlinkEscapeDenied() async throws {
        let access = CodingWorkspaceAccess()
        let token = try await access.enable()
        let root = try await access.addRoot(path: directory("repo"))
        let outside = try directory("repo2")
        let link = root.path + "/escape"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        for path in [outside, root.path + "/../repo2", link] {
            await expect(.outsideRoot) {
                _ = try await access.authorize(credential: token, rootID: root.id, directory: path)
            }
        }
    }

    func testReplacementSymlinkFailsClosed() async throws {
        let access = CodingWorkspaceAccess()
        let token = try await access.enable()
        let root = try await access.addRoot(path: directory("repo"))
        let outside = try directory("elsewhere")
        try FileManager.default.removeItem(atPath: root.path)
        try FileManager.default.createSymbolicLink(atPath: root.path, withDestinationPath: outside)
        await expect(.outsideRoot) {
            _ = try await access.authorize(credential: token, rootID: root.id, directory: root.path)
        }
    }

    func testRevocationAndRotationInvalidateGrants() async throws {
        let access = CodingWorkspaceAccess()
        let old = try await access.enable()
        let root = try await access.addRoot(path: temporary.path)
        await access.removeRoot(id: root.id)
        await expect(.unknownRoot) {
            _ = try await access.authorize(credential: old, rootID: root.id, directory: self.temporary.path)
        }
        _ = try await access.addRoot(path: temporary.path)
        let new = try await access.enable()
        XCTAssertNotEqual(old, new)
        await expect(.unauthorized) { _ = try await access.approvedRoots(credential: old) }
        let roots = try await access.approvedRoots(credential: new)
        XCTAssertTrue(roots.isEmpty)
        await access.disable()
        await expect(.disabled) { _ = try await access.approvedRoots(credential: new) }
    }

    func testInvalidPathsAndFilesAreRejected() async throws {
        let access = CodingWorkspaceAccess()
        _ = try await access.enable()
        let file = temporary.appendingPathComponent("file")
        try Data().write(to: file)
        for path in ["relative", "", temporary.path + "/absent", file.path, temporary.path + "\0ignored"] {
            await expect(.invalidDirectory) { _ = try await access.addRoot(path: path) }
        }
    }
}
