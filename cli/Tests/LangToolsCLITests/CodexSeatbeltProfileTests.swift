import Foundation
import XCTest
@testable import LangToolsCLI

final class CodexSeatbeltProfileTests: XCTestCase {
    func testSandboxExecAvailableOnMacOS() {
        // The CI/test host is macOS; sandbox-exec must be present for the
        // OS-level read boundary to apply.
        #if os(macOS)
        XCTAssertTrue(CodexSeatbeltProfile.isAvailable(), "sandbox-exec must be available on macOS to enforce Codex read containment.")
        XCTAssertNotNil(CodexSeatbeltProfile.sandboxExecPath())
        #endif
    }

    func testProfileDeniesReadsOutsideWorkspaceAndAllowsInside() throws {
        guard let sandboxExec = CodexSeatbeltProfile.sandboxExecPath() else {
            throw XCTSkip("Seatbelt containment is unavailable on this platform.")
        }

        let workspaceRoot = makeTempDir(prefix: "ws")
        let codexHome = makeTempDir(prefix: "codexhome")
        let sentinelInside = workspaceRoot.appendingPathComponent("inside.txt")
        try "workspace-content".write(to: sentinelInside, atomically: true, encoding: .utf8)
        let codexFile = codexHome.appendingPathComponent("auth.json")
        try "{\"auth\":\"ok\"}".write(to: codexFile, atomically: true, encoding: .utf8)

        // A sensitive sentinel OUTSIDE the allowlist (under the user home).
        let homeSentinel = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("seatbelt-sentinel-\(UUID().uuidString.lowercased()).txt")
        try "SECRET".write(to: homeSentinel, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot)
            try? FileManager.default.removeItem(at: codexHome)
            try? FileManager.default.removeItem(at: homeSentinel)
        }

        let inputs = CodexSeatbeltProfile.Inputs(
            codexExecutable: "/usr/bin/python3",
            codexExecutableArguments: [],
            codexHome: codexHome.path,
            workspaceRoot: workspaceRoot.path
        )
        let profileURL = try CodexSeatbeltProfile().writeProfile(inputs: inputs)
        defer { try? FileManager.default.removeItem(at: profileURL) }

        // Inside-workspace read must succeed.
        XCTAssertEqual(
            runSandboxed(sandboxExec: sandboxExec, profile: profileURL, argv: ["/bin/cat", sentinelInside.path]),
            0,
            "Reading inside the workspace must be permitted."
        )
        // Codex home must be readable.
        XCTAssertEqual(
            runSandboxed(sandboxExec: sandboxExec, profile: profileURL, argv: ["/bin/cat", codexFile.path]),
            0,
            "Reading the Codex home directory must be permitted."
        )
        // A system file must be readable (networking/runtime need it).
        XCTAssertEqual(
            runSandboxed(sandboxExec: sandboxExec, profile: profileURL, argv: ["/bin/cat", "/etc/hosts"]),
            0,
            "Reading system files must remain permitted."
        )
        // Native tool execution must work (preserves Codex-native tools). Use a
        // self-contained shell binary rather than `/usr/bin/python3`, which is an
        // `xcrun` shim on some macOS hosts and pulls in Xcode libraries outside
        // the containment allowlist.
        XCTAssertEqual(
            runSandboxed(sandboxExec: sandboxExec, profile: profileURL, argv: ["/bin/sh", "-c", "echo ok"]),
            0,
            "Native tool execution must remain available."
        )
        // Reading a user file outside the workspace/codex-home allowlist must be DENIED.
        XCTAssertNotEqual(
            runSandboxed(sandboxExec: sandboxExec, profile: profileURL, argv: ["/bin/cat", homeSentinel.path]),
            0,
            "Reading user files outside the workspace must be denied by the OS."
        )
        // Writing inside the workspace must succeed.
        let writeTarget = workspaceRoot.appendingPathComponent("out.txt")
        XCTAssertEqual(
            runSandboxed(sandboxExec: sandboxExec, profile: profileURL, argv: ["/bin/sh", "-c", "echo y > \(writeTarget.path)"]),
            0,
            "Writing inside the workspace must be permitted."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: writeTarget.path))
        // Writing outside the workspace must be DENIED.
        let homeWrite = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("seatbelt-write-\(UUID().uuidString.lowercased()).txt")
        XCTAssertNotEqual(
            runSandboxed(sandboxExec: sandboxExec, profile: profileURL, argv: ["/bin/sh", "-c", "echo y > \(homeWrite.path)"]),
            0,
            "Writing user files outside the workspace must be denied by the OS."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: homeWrite.path))
    }

    func testProfileEscapesPathsAndRendersExpectedDirectives() throws {
        let inputs = CodexSeatbeltProfile.Inputs(
            codexExecutable: "/opt/codex/bin/codex",
            codexExecutableArguments: [],
            codexHome: "/tmp/codex-home",
            workspaceRoot: "/tmp/ws root"
        )
        let source = CodexSeatbeltProfile().render(inputs: inputs)
        XCTAssertTrue(source.contains("(deny default)"))
        XCTAssertTrue(source.contains("(import \"system.sb\")"))
        XCTAssertTrue(source.contains("(allow process-exec process-fork signal)"))
        XCTAssertTrue(source.contains("(allow network*)"))
        // Workspace path with a space is quoted and preserved.
        XCTAssertTrue(source.contains("(allow file-read* (subpath \"/tmp/ws root\"))"))
        XCTAssertTrue(source.contains("(allow file-write* (subpath \"/tmp/ws root\"))"))
        XCTAssertTrue(source.contains("(allow file-read* (subpath \"/tmp/codex-home\"))"))
        XCTAssertTrue(source.contains("(allow file-write* (subpath \"/tmp/codex-home\"))"))
        XCTAssertTrue(source.contains("(allow file-write* (literal \"/dev/null\"))"))
    }

    func testResolvedCodexHomeHonorsEnvironmentPrecedence() {
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        XCTAssertEqual(
            CodexSeatbeltProfile.resolvedCodexHome(environment: [:]),
            URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            CodexSeatbeltProfile.resolvedCodexHome(environment: ["CODEX_HOME": "/custom/codex"]),
            URL(fileURLWithPath: "/custom/codex").resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            CodexSeatbeltProfile.resolvedCodexHome(environment: ["LANGTOOLS_CODEX_HOME": "/override/codex", "CODEX_HOME": "/custom/codex"]),
            URL(fileURLWithPath: "/override/codex").resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            CodexSeatbeltProfile.resolvedCodexHome(environment: ["CODEX_HOME": ""]),
            URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        )
    }

    // MARK: - Helpers

    private func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seatbelt-\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func runSandboxed(sandboxExec: String, profile: URL, argv: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxExec)
        process.arguments = ["-f", profile.path] + argv
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}