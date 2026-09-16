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
        // A runtime-cache root the helper owns, to prove the grant works at
        // runtime (not just as rendered text).
        let runtimeCache = makeTempDir(prefix: "cache")
        let cacheFile = runtimeCache.appendingPathComponent("plugin-cache.json")
        try "cache-content".write(to: cacheFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: workspaceRoot)
            try? FileManager.default.removeItem(at: codexHome)
            try? FileManager.default.removeItem(at: homeSentinel)
            try? FileManager.default.removeItem(at: runtimeCache)
        }

        let inputs = CodexSeatbeltProfile.Inputs(
            codexExecutable: "/usr/bin/python3",
            codexExecutableArguments: [],
            codexHome: codexHome.path,
            workspaceRoot: workspaceRoot.path,
            codexRuntimeCache: runtimeCache.path,
            homeDirectory: NSHomeDirectory()
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
        // Runtime-cache reads must succeed (the grant is proven at runtime).
        XCTAssertEqual(
            runSandboxed(sandboxExec: sandboxExec, profile: profileURL, argv: ["/bin/cat", cacheFile.path]),
            0,
            "Reading the codex runtime cache must be permitted."
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
        // Metadata of the same denied path must be ALLOWED: this pins the exact
        // (intentional) boundary — global stat, contents denied-by-default.
        XCTAssertEqual(
            runSandboxed(sandboxExec: sandboxExec, profile: profileURL, argv: ["/usr/bin/stat", "-f%z", homeSentinel.path]),
            0,
            "Metadata probing must remain permitted (documented accepted risk)."
        )
        // Credential-store locations are explicitly denied for metadata too,
        // for every blocklist entry that exists under the real home.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        for sensitive in ["~/.ssh", "~/.gnupg", "~/.aws", "~/.gitconfig", "~/Library/Keychains"] {
            let expanded = home.appendingPathComponent(
                sensitive.replacingOccurrences(of: "~/", with: "")
            )
            guard FileManager.default.fileExists(atPath: expanded.path) else { continue }
            XCTAssertNotEqual(
                runSandboxed(sandboxExec: sandboxExec, profile: profileURL, argv: ["/usr/bin/stat", expanded.path]),
                0,
                "Metadata probing of \(sensitive) must be denied by the blocklist."
            )
        }
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
            workspaceRoot: "/tmp/ws root",
            codexRuntimeCache: "",
            homeDirectory: ""
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

    func testRenderIncludesRuntimeCacheRulesWithQuotedPaths() throws {
        let inputs = CodexSeatbeltProfile.Inputs(
            codexExecutable: "/opt/codex/bin/codex",
            codexExecutableArguments: [],
            codexHome: "/tmp/codex-home",
            workspaceRoot: "/tmp/ws root",
            codexRuntimeCache: "/tmp/cache dir/codex-runtimes",
            homeDirectory: ""
        )
        let source = CodexSeatbeltProfile().render(inputs: inputs)
        XCTAssertTrue(source.contains("(allow file-read* (subpath \"/tmp/cache dir/codex-runtimes\"))"))
        XCTAssertTrue(source.contains("(allow file-write* (subpath \"/tmp/cache dir/codex-runtimes\"))"))
        // Runtime operations are part of the profile, scoped to the services
        // codex actually requested (enumerated from sandbox denial reports).
        XCTAssertTrue(source.contains("(allow mach-lookup"))
        XCTAssertTrue(source.contains("\"com.apple.SystemConfiguration.configd\""))
        XCTAssertTrue(source.contains("(allow system-socket (socket-domain 32))"))
        XCTAssertTrue(source.contains(
            "(allow user-preference-read (preference-domain \"com.openai.codex\"))"
        ))
        XCTAssertTrue(source.contains("(allow file-read-metadata)"))
        XCTAssertFalse(source.contains("(allow mach-lookup)\n)"))
        // The credential blocklist derives from the passwd database (not the
        // inputs), so it renders even without an input home — and covers both
        // the lexical and resolved home locations.
        XCTAssertTrue(source.contains("(deny file-read-metadata (subpath \"\(NSHomeDirectory())/Library/Keychains\"))"))
        // No runtime-cache rules are emitted when no cache is configured.
        let empty = CodexSeatbeltProfile().render(inputs: CodexSeatbeltProfile.Inputs(
            codexExecutable: "/opt/codex/bin/codex",
            codexExecutableArguments: [],
            codexHome: "/tmp/codex-home",
            workspaceRoot: "/tmp/ws root",
            codexRuntimeCache: "",
            homeDirectory: ""
        ))
        XCTAssertFalse(empty.contains("codex-runtimes"))
    }

    func testResolvedRuntimeCacheCreatesMissingDirectoryWithOwnerOnlyPermissions() throws {
        let home = makeTempDir(prefix: "home")
        defer { try? FileManager.default.removeItem(at: home) }

        let cache = CodexSeatbeltProfile.resolvedCodexRuntimeCache(environment: ["HOME": home.path])
        // The implementation deliberately returns the lexical path.
        XCTAssertEqual(cache, home.appendingPathComponent(".cache/codex-runtimes").standardizedFileURL.path)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let permissions = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: cache)[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(permissions & 0o777, 0o700)
    }

    func testResolvedRuntimeCacheRefusesSymlinkedCacheDirectory() throws {
        let home = makeTempDir(prefix: "home")
        let target = makeTempDir(prefix: "target")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".cache/codex-runtimes"),
            withDestinationURL: target
        )

        // A planted symlink must not widen the read/write grant to its target.
        XCTAssertEqual(CodexSeatbeltProfile.resolvedCodexRuntimeCache(environment: ["HOME": home.path]), "")
    }

    func testResolvedRuntimeCacheRefusesSymlinkedCacheParent() throws {
        let home = makeTempDir(prefix: "home")
        let target = makeTempDir(prefix: "target")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".cache"),
            withDestinationURL: target
        )

        XCTAssertEqual(CodexSeatbeltProfile.resolvedCodexRuntimeCache(environment: ["HOME": home.path]), "")
    }

    func testResolvedRuntimeCacheRefusesNonDirectoryPath() throws {
        let home = makeTempDir(prefix: "home")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: home.appendingPathComponent(".cache/codex-runtimes"))

        XCTAssertEqual(CodexSeatbeltProfile.resolvedCodexRuntimeCache(environment: ["HOME": home.path]), "")
    }

    func testResolvedRuntimeCacheRefusesMissingOrEmptyHome() {
        XCTAssertEqual(CodexSeatbeltProfile.resolvedCodexRuntimeCache(environment: [:]), "")
        XCTAssertEqual(CodexSeatbeltProfile.resolvedCodexRuntimeCache(environment: ["HOME": ""]), "")
    }

    func testResolvedRuntimeCacheRefusesForeignOwnedDirectory() throws {
        let home = makeTempDir(prefix: "home")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cache/codex-runtimes"),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            CodexSeatbeltProfile.resolvedCodexRuntimeCache(
                environment: ["HOME": home.path],
                currentUserID: 424_242
            ),
            ""
        )
        // The real owner is still granted.
        XCTAssertNotEqual(
            CodexSeatbeltProfile.resolvedCodexRuntimeCache(environment: ["HOME": home.path]),
            ""
        )
    }

    func testResolvedRuntimeCacheRefusesGroupOrOtherWritableLeaf() throws {
        let home = makeTempDir(prefix: "home")
        defer { try? FileManager.default.removeItem(at: home) }
        let leaf = home.appendingPathComponent(".cache/codex-runtimes")
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o707))],
            ofItemAtPath: leaf.path
        )

        // Group/other-writable cached runtime data could be tampered with by
        // other local users and then read back by the sandboxed process.
        XCTAssertEqual(CodexSeatbeltProfile.resolvedCodexRuntimeCache(environment: ["HOME": home.path]), "")

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o770))],
            ofItemAtPath: leaf.path
        )
        XCTAssertEqual(CodexSeatbeltProfile.resolvedCodexRuntimeCache(environment: ["HOME": home.path]), "")
    }

    func testResolvedRuntimeCacheSetsIntermediateCachePermissions() throws {
        let home = makeTempDir(prefix: "home")
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertNotNil(CodexSeatbeltProfile.resolvedCodexRuntimeCache(environment: ["HOME": home.path]))

        let root = home.appendingPathComponent(".cache")
        // The intermediate follows the XDG convention (0755); the helper-owned
        // leaf is owner-only (0700).
        for (path, mode) in [(root, 0o755), (root.appendingPathComponent("codex-runtimes"), 0o700)] {
            let permissions = try XCTUnwrap(
                (try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue
            )
            XCTAssertEqual(permissions & 0o777, mode, "\(path.path) has the wrong mode")
        }
    }

    func testResolvedRuntimeCachePreservesExistingParentPermissionsAndVerifiesOwnership() throws {
        let home = makeTempDir(prefix: "home")
        defer { try? FileManager.default.removeItem(at: home) }
        let parent = home.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: parent.path
        )

        let cache = CodexSeatbeltProfile.resolvedCodexRuntimeCache(environment: ["HOME": home.path])
        XCTAssertEqual(cache, home.appendingPathComponent(".cache/codex-runtimes").standardizedFileURL.path)

        // Leaf is created owner-only; the pre-existing parent keeps its mode.
        let leafPermissions = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: cache)[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(leafPermissions & 0o777, 0o700)
        let parentPermissions = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(parentPermissions & 0o777, 0o755)
    }

    func testExitedErrorTruncatesStderrDetail() {
        let short = CodexAppServerError.exited(status: 1, stderr: "boom\n")
        XCTAssertEqual(short.errorDescription, "Codex app-server exited with status 1: boom")

        let blank = CodexAppServerError.exited(status: 1, stderr: "   \n")
        XCTAssertEqual(blank.errorDescription, "Codex app-server exited with status 1.")

        // Control characters are sanitized (terminal escapes cannot reach logs/UI).
        let escape = CodexAppServerError.exited(status: 1, stderr: "bad\u{1B}[31mcolor\n").errorDescription ?? ""
        XCTAssertFalse(escape.contains("\u{1B}"))
        XCTAssertTrue(escape.contains("bad [31mcolor"))

        // Byte budget, not Character count: 2,048 UTF-8 bytes.
        let multiByte = String(repeating: "日", count: 5_000) // 15,000 bytes
        let truncatedBytes = CodexAppServerError.exited(status: 3, stderr: multiByte).errorDescription ?? ""
        XCTAssertLessThanOrEqual(
            truncatedBytes.utf8.count,
            CodexAppServerError.maximumStderrDetailBytes + 64,
            "embedded stderr detail must stay within the byte budget"
        )

        // The tail of a crash log carries the failure reason.
        let long = String(repeating: "a", count: 3_000) + "FATAL-REASON"
        let tail = CodexAppServerError.exited(status: 4, stderr: long).errorDescription ?? ""
        XCTAssertTrue(tail.hasSuffix("FATAL-REASON[truncated]"))
        XCTAssertFalse(tail.hasPrefix("aaa"))

        // A multi-byte character split by the byte boundary is trimmed at the
        // continuation boundary: the kept tail is exactly 682 complete
        // characters (2048 bytes = 682 x 3 + 2), never a corrupted glyph.
        let split = String(repeating: "日", count: 1_025) // boundary splits the last char
        let splitDetail = CodexAppServerError.exited(status: 6, stderr: split).errorDescription ?? ""
        XCTAssertEqual(
            splitDetail,
            "Codex app-server exited with status 6: …" + String(repeating: "日", count: 682) + "[truncated]"
        )
    }

    func testLaunchedProcessRunsInsideWorkspaceRootUnderSeatbelt() async throws {
        guard CodexSeatbeltProfile.sandboxExecPath() != nil else {
            throw XCTSkip("Seatbelt containment is unavailable on this platform.")
        }
        let workspace = makeTempDir(prefix: "ws")
        defer { try? FileManager.default.removeItem(at: workspace) }
        // The marker is first written with a RELATIVE path (proving the child's
        // cwd — the resolved Codex home — is itself writable under the
        // seatbelt), then copied into the workspace so the test can read it
        // after the startup failure.
        let marker = workspace.appendingPathComponent("cwd-marker.txt")
        let expectedCWD = CodexSeatbeltProfile.resolvedCodexHome(environment: [:])

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(
                    executable: "/bin/sh",
                    arguments: ["-c", "pwd > marker.txt && cp marker.txt '\(marker.path)'"]
                )
            },
            workspaceRootProvider: { workspace }
        )
        // Startup launches the command under the seatbelt with its working
        // directory in the dedicated per-launch temp directory; the fake
        // command records its cwd and exits, so startup fails, but the marker
        // proves where it ran.
        _ = try? await client.initializedProcessGeneration()

        let deadline = Date().addingTimeInterval(10)
        var recorded: String?
        while Date() < deadline, recorded == nil {
            recorded = (try? String(contentsOf: marker, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if recorded == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        // getcwd returns the physical path (/private/var for /var on macOS).
        // The child runs in the resolved Codex home, not the workspace root or
        // the helper launch directory.
        XCTAssertEqual(recorded.map(Self.physicalPath), Self.physicalPath(expectedCWD))
        await client.shutdown()
        // The Codex home is user data: shutdown must never remove it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedCWD))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLaunchedProcessKeepsInheritedWorkingDirectoryWithoutSeatbelt() async throws {
        // Without a workspace root there is no seatbelt launch, and the prior
        // behavior is preserved: the child inherits the helper's cwd rather
        // than being pointed at a workspace.
        let workspace = makeTempDir(prefix: "ws")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let marker = workspace.appendingPathComponent("cwd-marker-no-seatbelt.txt")

        // Snapshot before the child launches: the test process cwd must not
        // change while the child inherits it.
        let expectedInherited = Self.physicalPath(FileManager.default.currentDirectoryPath)
        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/bin/sh", arguments: ["-c", "pwd > '\(marker.path)'"])
            },
            workspaceRootProvider: { nil }
        )
        _ = try? await client.initializedProcessGeneration()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, FileManager.default.fileExists(atPath: marker.path) == false {
            try await Task.sleep(for: .milliseconds(20))
        }
        let recorded = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(recorded.map(Self.physicalPath), expectedInherited)
        XCTAssertNotEqual(recorded.map(Self.physicalPath), Self.physicalPath(workspace.path))
        await client.shutdown()
    }

    func testMissingWorkspaceRootFailsClosedBeforeLaunching() async throws {
        guard CodexSeatbeltProfile.sandboxExecPath() != nil else {
            throw XCTSkip("Seatbelt containment is unavailable on this platform.")
        }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-ws-\(UUID().uuidString.lowercased())", isDirectory: true)

        let client = CodexAppServerClient(
            commandResolver: {
                ResolvedCodexCommand(executable: "/bin/sh", arguments: ["-c", "exit 0"])
            },
            workspaceRootProvider: { missing }
        )
        do {
            _ = try await client.initializedProcessGeneration()
            XCTFail("Expected the missing workspace root to fail closed")
        } catch let error as CodexAppServerError {
            guard case .transport(let message) = error else {
                return XCTFail("Expected a transport error, got \(error)")
            }
            XCTAssertTrue(message.contains("workspace root is missing"), message)
        }
        await client.shutdown()
    }

    func testRenderDeniesMetadataProbingOfEveryCredentialStore() throws {
        // The blocklist home is the passwd home for the effective user, not
        // the input value (which is only a fallback); standardized to match
        // sensitiveCredentialPaths.
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let source = CodexSeatbeltProfile().render(inputs: CodexSeatbeltProfile.Inputs(
            codexExecutable: "/opt/codex/bin/codex",
            codexExecutableArguments: [],
            codexHome: "/tmp/codex-home",
            workspaceRoot: "/tmp/ws root",
            codexRuntimeCache: "/tmp/cache dir/codex-runtimes",
            homeDirectory: home
        ))
        for sensitive in CodexSeatbeltProfile.sensitiveCredentialStoreNames {
            XCTAssertTrue(
                source.contains("(deny file-read-metadata (subpath \"\(home)/\(sensitive)\"))"),
                "missing metadata blocklist entry for \(sensitive)"
            )
        }
        XCTAssertTrue(source.contains("(deny file-read-metadata (subpath \"\(home)/Library/Keychains\"))"))
        // Broad trees (.config, Application Support, Preferences) are
        // intentionally NOT denied: legitimate XDG/app-support probes run
        // through them, and their secret content is protected by the content
        // boundary anyway.
        XCTAssertFalse(
            source.contains("(deny file-read-metadata (subpath \"\(home)/Library/Application Support\"))"),
            "broad application-support tree must not be denied"
        )
        XCTAssertFalse(
            source.contains("(deny file-read-metadata (subpath \"\(home)/Library/Preferences\"))"),
            "broad preferences tree must not be denied"
        )
        // The mach-lookup enumeration stays pinned to the requested services.
        for service in ["coreservicesd", "diskarbitrationd", "FSEvents", "SecurityServer",
                        "configd", "SCNetworkReachability", "networkd", "dnssd"] {
            XCTAssertTrue(source.contains(service), "missing mach service \(service)")
        }
        XCTAssertFalse(source.contains("(allow mach-lookup)\n)"))
    }

    func testCredentialBlocklistHomePrefersPasswdDatabaseOverHOME() {
        // The passwd home for the effective user is authoritative: a wrong or
        // symlinked $HOME cannot redirect the credential-store denies. In this
        // unsandboxed test environment the passwd home equals NSHomeDirectory().
        let resolved = CodexSeatbeltProfile.credentialBlocklistHome(environment: ["HOME": "/nonexistent-home"])
        XCTAssertEqual(resolved, URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
    }

    func testSensitiveCredentialPathsStandardizeAndCoverStores() {
        // A trailing slash on the home cannot disable a deny.
        let paths = CodexSeatbeltProfile.sensitiveCredentialPaths(home: "/Users/reid/")
        XCTAssertTrue(paths.contains("/Users/reid/.ssh"))
        XCTAssertTrue(paths.contains("/Users/reid/Library/Keychains"))
        XCTAssertFalse(paths.contains("/Users/reid//.ssh"))
        // Broad trees are intentionally not denied.
        XCTAssertFalse(paths.contains("/Users/reid/.config"))
        XCTAssertFalse(paths.contains("/Users/reid/Library/Application Support"))
        XCTAssertFalse(paths.contains("/Users/reid/Library/Preferences"))
    }

    // MARK: - Helpers

    private static func physicalPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

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