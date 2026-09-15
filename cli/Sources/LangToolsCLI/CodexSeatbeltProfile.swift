import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// An OS-enforced (macOS seatbelt) read-containment profile for the Codex
/// app-server process and every command it spawns.
///
/// The profile is deny-by-default for file access and re-allows only the
/// roots Codex needs to function: system runtime paths, the Codex home
/// directory (auth/config/cache), the helper-owned conversation workspace
/// root, and process temporary directories. Reads of the user's home tree
/// (`~/.ssh`, `~/Documents`, `~/.aws`, …) and any other non-allowlisted path
/// are denied by the kernel, so a prompt or prompt injection cannot exfiltrate
/// user files through the model. Native Codex tools keep working because
/// `process-exec`/`process-fork`/`network` remain allowed; spawned commands
/// inherit the same seatbelt, so they cannot read outside the allowlist
/// either.
struct CodexSeatbeltProfile: Sendable {
    struct Inputs: Sendable {
        /// Path to the Codex executable (or runtime such as `node`/`bun`)
        /// exactly as resolved by `OpenAIAccountChatCommand.resolveCodexCommand`.
        let codexExecutable: String
        /// Arguments for a runtime-backed command (e.g. `["…/dist/cli.js"]`).
        /// Empty for a self-contained Codex binary.
        let codexExecutableArguments: [String]
        /// Resolved Codex home directory (`LANGTOOLS_CODEX_HOME`/`CODEX_HOME`
        /// or `~/.codex`).
        let codexHome: String
        /// Helper-owned workspace root containing all conversation workspaces
        /// for this helper process lifetime.
        let workspaceRoot: String
        /// Codex runtime/plugin cache (e.g. `~/.cache/codex-runtimes`). Empty
        /// when it does not exist.
        let codexRuntimeCache: String
    }

    /// Returns the absolute path to `sandbox-exec` when seatbelt containment is
    /// available, otherwise `nil` (non-macOS or missing binary).
    static func sandboxExecPath() -> String? {
        #if os(macOS)
        let path = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
        #else
        return nil
        #endif
    }

    /// True when seatbelt read containment can be applied.
    static func isAvailable() -> Bool {
        sandboxExecPath() != nil
    }

    /// Resolves the active Codex home using the documented precedence:
    /// `LANGTOOLS_CODEX_HOME`, then `CODEX_HOME`, then `~/.codex`.
    static func resolvedCodexHome(environment: [String: String]) -> String {
        for key in ["LANGTOOLS_CODEX_HOME", "CODEX_HOME"] {
            if let value = environment[key], value.isEmpty == false {
                return Self.standardizedResolving(value)
            }
        }
        return Self.standardizedResolving(
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".codex").path
        )
    }

    /// Resolves (creating when missing) the Codex runtime/plugin cache
    /// directory.
    ///
    /// Fail-closed hardening: the seatbelt grants read/write on this directory,
    /// and the helper does not own `~/.cache`, so the grant is only issued when
    /// neither cache component is a symlink (a planted symlink would otherwise
    /// hand the grant a target path directly), the path is a real directory
    /// owned by the effective user, and a missing directory can be created
    /// helper-owned (mode 0700, including the intermediate `.cache` when the
    /// helper creates it). Otherwise no grant is issued and Codex simply runs
    /// without this cache rather than gaining access to an unexpected location.
    ///
    /// Seatbelt evaluates file operations against symlink-resolved paths, so a
    /// symlink swapped in after launch resolves to a non-allowlisted target and
    /// stays denied; the checks here prevent issuing a wide grant up front.
    /// A pre-existing directory's mode is intentionally left untouched: the
    /// grant only applies to the sandboxed Codex process running as the same
    /// user, and existing filesystem permissions still bound everyone else.
    static func resolvedCodexRuntimeCache(
        environment: [String: String],
        currentUser: String = NSUserName(),
        fileManager: FileManager = .default
    ) -> String {
        guard let home = environment["HOME"], home.isEmpty == false else { return "" }
        let cacheRoot = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".cache", isDirectory: true)
        let cachePath = cacheRoot.appendingPathComponent("codex-runtimes", isDirectory: true)
        let lexicalPath = cachePath.standardizedFileURL.path
        let lexicalRoot = cacheRoot.standardizedFileURL.path

        guard Self.isSymlink(at: lexicalPath, fileManager: fileManager) == false,
              Self.isSymlink(at: lexicalRoot, fileManager: fileManager) == false
        else { return "" }

        var isDirectory: ObjCBool = false
        let rootExisted = fileManager.fileExists(atPath: lexicalRoot, isDirectory: &isDirectory)
        if fileManager.fileExists(atPath: lexicalPath, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return "" }
        } else {
            do {
                try fileManager.createDirectory(
                    at: cachePath,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
                )
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o700))],
                    ofItemAtPath: lexicalPath
                )
                // createDirectory applies explicit attributes only to the final
                // component; keep the helper-created .cache owner-only too.
                if rootExisted == false {
                    try fileManager.setAttributes(
                        [.posixPermissions: NSNumber(value: Int16(0o700))],
                        ofItemAtPath: lexicalRoot
                    )
                }
            } catch {
                return ""
            }
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: lexicalPath),
              let owner = attributes[.ownerAccountName] as? String,
              owner == currentUser
        else { return "" }

        // Match workspaceRoot handling: grant the symlink-resolved location the
        // kernel will evaluate (a no-op when no component is a symlink).
        return URL(fileURLWithPath: lexicalPath).resolvingSymlinksInPath().path
    }

    private static func isSymlink(at path: String, fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private static func standardizedResolving(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    /// Renders the seatbelt profile source for the given inputs.
    func render(inputs: Inputs) -> String {
        let codexHome = Self.quoted(inputs.codexHome)
        let workspaceRoot = Self.quoted(inputs.workspaceRoot)
        // Apple's canonical shared seatbelt profile (shipped at
        // /System/Library/Sandbox/Profiles/system.sb and imported by Apple's
        // own /usr/share/sandbox profiles). It supplies the boilerplate allows
        // a process needs to exec/load under deny-default; without it deny-default
        // aborts at startup. Loadability is exercised by the real sandbox-exec tests.
        var lines: [String] = [
            "(version 1)",
            "(deny default)",
            "(import \"system.sb\")",
            "(allow process-exec process-fork signal)",
            "(allow network*)",
            // Codex's HTTP stack (Rust reqwest/hyper) needs SystemConfiguration,
            // network extension sockets, and DNS resolution to reach the backend;
            // enumerating every mach service it touches is fragile, and mach IPC
            // does not expose user files, so mach lookup stays broad. File reads
            // remain the enforced boundary below.
            //
            // Accepted trade-off: `user-preference-read` is intentionally global.
            // Codex reads both its own `com.openai.codex` domain and
            // kCFPreferencesAnyApplication, so it cannot be scoped to one domain
            // without breaking it. This exposes CFPreferences/NSUserDefaults
            // values (app settings; some apps store credentials in prefs) but
            // not user documents; the filesystem read boundary is unaffected.
            "(allow mach-lookup)",
            "(allow system-socket)",
            "(allow user-preference-read)",
            // Allow stat/metadata of any path (low-risk: exposes existence only,
            // not contents) so the sandboxed process can resolve absolute path
            // components. Content reads remain denied-by-default below.
            "(allow file-read-metadata)"
        ]
        // System runtime roots Codex and its native tools need to exec/load.
        for root in Self.systemReadRoots {
            lines.append("(allow file-read* (subpath \(Self.quoted(root))))")
        }
        // Codex executable + runtime resources (covers npm/node installs that
        // may live under the user home tree, which is otherwise denied).
        let executableReadRoots = Self.executableReadRoots(
            executable: inputs.codexExecutable,
            arguments: inputs.codexExecutableArguments
        )
        for root in executableReadRoots {
            lines.append("(allow file-read* (subpath \(Self.quoted(root))))")
        }
        // Codex owns its credential/config/cache directory.
        lines.append("(allow file-read* (subpath \(codexHome)))")
        lines.append("(allow file-write* (subpath \(codexHome)))")
        // Codex runtime/plugin cache (models cache, primary runtime plugins).
        if inputs.codexRuntimeCache.isEmpty == false {
            let runtimeCache = Self.quoted(inputs.codexRuntimeCache)
            lines.append("(allow file-read* (subpath \(runtimeCache)))")
            lines.append("(allow file-write* (subpath \(runtimeCache)))")
        }
        // Helper-owned conversation workspaces.
        lines.append("(allow file-read* (subpath \(workspaceRoot)))")
        lines.append("(allow file-write* (subpath \(workspaceRoot)))")
        // Process temporary directories.
        for root in Self.tempWriteRoots {
            lines.append("(allow file-read* (subpath \(Self.quoted(root))))")
            lines.append("(allow file-write* (subpath \(Self.quoted(root))))")
        }
        lines.append("(allow file-write* (literal \"/dev/null\"))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the rendered profile to a mode-0600 temporary file and returns
    /// its URL. The caller owns cleanup.
    func writeProfile(inputs: Inputs) throws -> URL {
        let source = render(inputs: inputs)
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("langtools-codex-seatbelt", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let profileURL = tempDirectory
            .appendingPathComponent("profile-\(UUID().uuidString.lowercased()).sb")
        try source.write(to: profileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: profileURL.path
        )
        return profileURL
    }

    private static let systemReadRoots: [String] = [
        "/usr",
        "/System",
        "/bin",
        "/sbin",
        "/lib",
        "/Library",
        "/etc",
        "/private/etc",
        "/private/var",
        "/dev",
        "/opt"
    ]

    private static let tempWriteRoots: [String] = [
        "/tmp",
        "/private/tmp",
        "/private/var/folders"
    ]

    private static func executableReadRoots(executable: String, arguments: [String]) -> [String] {
        var roots = Set<String>()
        let resolvedExecutable = URL(fileURLWithPath: executable)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent().path
        roots.insert(resolvedExecutable)
        // The original (possibly symlink) executable's directory, in case the
        // resolved real binary lives elsewhere and the symlink directory is
        // not already covered by a system root.
        let literalParent = URL(fileURLWithPath: executable)
            .deletingLastPathComponent().standardizedFileURL.path
        roots.insert(literalParent)
        if let firstArgument = arguments.first,
           firstArgument.hasSuffix(".js") || firstArgument.hasSuffix(".mjs") || firstArgument.hasSuffix(".ts") {
            let resourceRoot = URL(fileURLWithPath: firstArgument)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent().path
            roots.insert(resourceRoot)
            // Node/bun resolve modules up the tree; allow the nearest enclosing
            // package root (the directory containing the runtime script) and
            // its node_modules siblings by allowing two levels up as well.
            let twoUp = URL(fileURLWithPath: resourceRoot)
                .deletingLastPathComponent().deletingLastPathComponent().path
            roots.insert(twoUp)
        }
        return roots.sorted().filter { candidate in
            guard candidate.isEmpty == false else { return false }
            let resolved = URL(fileURLWithPath: candidate)
                .standardizedFileURL.resolvingSymlinksInPath().path
            let home = URL(fileURLWithPath: NSHomeDirectory())
                .standardizedFileURL.resolvingSymlinksInPath().path
            // Never grant read access to the user home itself or any of its
            // ancestors: that would defeat the read-containment boundary.
            // Descendants of home (e.g. a project install dir) remain allowed.
            if resolved == home { return false }
            if home.hasPrefix(resolved + "/") { return false }
            return true
        }
    }

    private static func quoted(_ path: String) -> String {
        // Seatbelt path literals are wrapped in double quotes; escape any
        // embedded quotes/backslashes.
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}