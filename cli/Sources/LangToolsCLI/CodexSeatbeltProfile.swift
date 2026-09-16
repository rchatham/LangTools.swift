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
        /// The user home directory; used only to block metadata probing of
        /// sensitive credential directories. Empty disables the blocklist.
        let homeDirectory: String
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
        currentUserID: UInt32 = UInt32(geteuid()),
        fileManager: FileManager = .default
    ) -> String {
        guard let home = environment["HOME"], home.isEmpty == false else { return "" }
        // A symlinked or foreign-owned HOME is not validated here: the lexical
        // grant below still fails safe under the seatbelt (accesses resolve to
        // locations the allowlist does not cover), it simply means the runtime
        // cache is unusable. Codex tolerates that.
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
        // The parent must be owned by the effective user and not group/other
        // writable regardless of whether the leaf pre-exists: a writable or
        // foreign-owned parent would let another local user swap the leaf
        // between the checks below and the grant.
        if rootExisted {
            guard let rootAttributes = try? fileManager.attributesOfItem(atPath: lexicalRoot),
                  let rootOwnerID = rootAttributes[.ownerAccountID] as? NSNumber,
                  rootOwnerID.uint32Value == currentUserID,
                  let rootPermissions = rootAttributes[.posixPermissions] as? NSNumber,
                  rootPermissions.intValue & 0o022 == 0
            else { return "" }
        }
        // Tracks filesystem state created by this call: if the final grant
        // checks refuse the path (e.g. a symlink planted after creation), the
        // helper-owned state is removed so it cannot be orphaned inside an
        // attacker-chosen target.
        var createdLeaf = false
        var createdRoot = false
        var grantIssued = false
        defer {
            if grantIssued == false {
                if createdLeaf {
                    try? fileManager.removeItem(atPath: lexicalPath)
                }
                if createdRoot {
                    try? fileManager.removeItem(atPath: lexicalRoot)
                }
            }
        }
        if fileManager.fileExists(atPath: lexicalPath, isDirectory: &isDirectory) {
            // A pre-existing leaf must be owned by the effective user and must
            // not be group/other-writable: other local users could otherwise
            // tamper with data the sandboxed process can read back, mirroring
            // the create path.
            guard isDirectory.boolValue,
                  let attributes = try? fileManager.attributesOfItem(atPath: lexicalPath),
                  let ownerID = attributes[.ownerAccountID] as? NSNumber,
                  ownerID.uint32Value == currentUserID,
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o022 == 0
            else { return "" }
        } else {
            do {
                createdLeaf = true
                try fileManager.createDirectory(
                    at: cachePath,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
                )
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o700))],
                    ofItemAtPath: lexicalPath
                )
                // Re-assert owner-only mode explicitly so the guarantee does
                // not depend on how Foundation applies attributes across the
                // intermediate-directory chain.
                if rootExisted == false {
                    // The intermediate .cache follows the XDG convention; only
                    // the leaf (helper-owned runtime data) is owner-only.
                    createdRoot = true
                    try fileManager.setAttributes(
                        [.posixPermissions: NSNumber(value: Int16(0o755))],
                        ofItemAtPath: lexicalRoot
                    )
                }
            } catch {
                return ""
            }
        }

        // Re-check symlink status on both components as late as possible:
        // attributesOfItem would follow a symlink planted between the first
        // check and here, vouching for a target's owner.
        guard Self.isSymlink(at: lexicalPath, fileManager: fileManager) == false,
              Self.isSymlink(at: lexicalRoot, fileManager: fileManager) == false
        else { return "" }

        grantIssued = true
        // Grant the lexical path, not a resolved one. Seatbelt evaluates file
        // operations against symlink-resolved paths, so the allowlist below
        // matches the physical location regardless; and if the directory is
        // swapped for a symlink after launch, accesses through it resolve to
        // the target and are denied because the target is not allowlisted.
        // Resolving here instead would hand a swapped-in target path directly
        // to the grant, so lexical is strictly safer.
        return lexicalPath
    }

    /// Credential/token stores whose metadata probing is denied even though
    /// global `file-read-metadata` is required for app-server startup.
    // Deliberately excludes broad trees (~/.config, ~/Library/Application
    // Support, ~/Library/Preferences): legitimate XDG/app-support probes run
    // through them and a metadata deny there risks breaking codex. Their
    // secret content stays protected by the deny-by-default content boundary.
    static let sensitiveCredentialStoreNames = [
        ".ssh",
        ".gnupg",
        ".aws",
        ".netrc",
        ".kube",
        ".docker",
        ".gitconfig",
        ".npmrc",
        ".pypirc",
        ".azure",
        ".cargo",
        ".terraform.d",
        ".vault",
        ".ansible"
    ]

    /// Resolves the credential-blocklist home from the passwd database for the
    /// effective user, falling back to the provided value (typically `$HOME`)
    /// and then to nothing. The passwd home is authoritative: a missing,
    /// non-canonical, or symlinked `$HOME` must not disable the denies.
    static func credentialBlocklistHome(
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String? {
        if let passwdHome = Self.passwdHomeForCurrentUser(), passwdHome.isEmpty == false {
            return passwdHome
        }
        guard let home = environment["HOME"], home.isEmpty == false else { return nil }
        let standardized = URL(fileURLWithPath: home).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return standardized
    }

    private static func passwdHomeForCurrentUser() -> String? {
        #if canImport(Darwin)
        guard let entry = getpwuid(geteuid()), entry.pointee.pw_dir != nil else { return nil }
        return String(cString: entry.pointee.pw_dir)
        #else
        return nil
        #endif
    }

    static func sensitiveCredentialPaths(home: String) -> [String] {
        // Specific credential stores only. Broad trees (~/.config,
        // ~/Library/Application Support, ~/Library/Preferences) are
        // intentionally NOT denied: legitimate XDG/app-support probes run
        // through them and a metadata deny there risks breaking codex, while
        // their secret content is protected by the content boundary anyway.
        let standardized = URL(fileURLWithPath: home).standardizedFileURL.path
        var paths = sensitiveCredentialStoreNames.map { standardized + "/" + $0 }
        paths.append(standardized + "/Library/Keychains")
        return paths
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
            // network sockets, and DNS resolution to reach the backend. Services
            // were enumerated empirically from sandbox denial reports while
            // running real codex turns under deny-default, then scoped to that
            // exact set: allowing every mach service would also expose
            // clipboard/contacts-class IPC to a prompt-injected process, and
            // file reads are not the only exfiltration channel.
            "(allow mach-lookup\n" +
                "   (global-name \"com.apple.CoreServices.coreservicesd\")\n" +
                "   (global-name \"com.apple.DiskArbitration.diskarbitrationd\")\n" +
                "   (global-name \"com.apple.FSEvents\")\n" +
                // securityd brokers per-key authorization; the lookup alone
                // does not unlock keychain items, and codex needs it for TLS
                // trust evaluation.
                "   (global-name \"com.apple.SecurityServer\")\n" +
                "   (global-name \"com.apple.SystemConfiguration.configd\")\n" +
                "   (global-name \"com.apple.SystemConfiguration.SCNetworkReachability\")\n" +
                "   (global-name \"com.apple.networkd\")\n" +
                "   (global-name \"com.apple.dnssd\")\n" +
                ")",
            // AF_SYSTEM control sockets only (domain 32, from the denial
            // reports); regular TCP/UDP is covered by network* above.
            "(allow system-socket (socket-domain 32))",
            // Scoped to Codex's own preference domain. Codex also probes
            // kCFPreferencesAnyApplication, which is denied and non-fatal;
            // scoping avoids exposing every app's CFPreferences/NSUserDefaults
            // domains (some apps store credentials in preferences).
            "(allow user-preference-read (preference-domain \"com.openai.codex\"))",
            // Database change-notification shared memory (CoreTypes).
            "(allow ipc-posix-shm-write-create (global-name \"com.apple.AppleDatabaseChanged\"))",
            // Allow stat/metadata of any path so the sandboxed process can
            // resolve absolute path components (parent directories of the
            // workspace/codex home are otherwise un-stat-able). Accepted risk,
            // stated explicitly: this permits existence/metadata probing of
            // arbitrary paths (e.g. ~/.ssh/config existing) but never contents;
            // content reads remain denied-by-default below. Narrowing this to
            // the allowlisted roots and their ancestor components was attempted
            // and empirically broke app-server startup, so the broad grant is
            // required for codex to run at all.
            // Even with global metadata allowed, credential-store locations
            // stay explicitly denied so existence probing of SSH/GnuPG/AWS
            // state is not possible; the specific denies below win over this
            // broader allow.
            "(allow file-read-metadata)"
        ]
        // The blocklist home comes from the passwd database for the effective
        // user, not $HOME: credential stores live in the real home, and a
        // missing/wrong/symlinked $HOME must not silently disable the denies.
        if let blocklistHome = Self.credentialBlocklistHome(environment: ["HOME": inputs.homeDirectory]) {
            // Denies must cover both the lexical and symlink-resolved home:
            // seatbelt matches resolved paths, so a home reached through a
            // symlink (e.g. /Users/me -> /Volumes/Data/me) would otherwise
            // bypass the lexical deny and fall through to the global allow.
            var blocklistHomes = Set([blocklistHome,
                                      URL(fileURLWithPath: blocklistHome).resolvingSymlinksInPath().path])
            // Each blocklist entry is denied under both its lexical and its
            // symlink-resolved location: seatbelt matches resolved paths, and
            // a per-entry symlink (e.g. ~/.ssh -> /Volumes/Key/.ssh) would
            // otherwise bypass the home-level deny.
            for home in blocklistHomes {
                for sensitivePath in Self.sensitiveCredentialPaths(home: home) {
                    lines.append("(deny file-read-metadata (subpath \(Self.quoted(sensitivePath))))")
                    let resolvedEntry = URL(fileURLWithPath: sensitivePath).resolvingSymlinksInPath().path
                    if resolvedEntry != sensitivePath {
                        lines.append("(deny file-read-metadata (subpath \(Self.quoted(resolvedEntry))))")
                    }
                }
            }
        }
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
        // Granted for both the lexical and the symlink-resolved location: a
        // symlinked HOME would otherwise leave the cache silently unusable.
        if inputs.codexRuntimeCache.isEmpty == false {
            let lexicalRuntimeCache = Self.quoted(inputs.codexRuntimeCache)
            lines.append("(allow file-read* (subpath \(lexicalRuntimeCache)))")
            lines.append("(allow file-write* (subpath \(lexicalRuntimeCache)))")
            let resolvedRuntimeCache = Self.quoted(
                URL(fileURLWithPath: inputs.codexRuntimeCache).resolvingSymlinksInPath().path
            )
            if resolvedRuntimeCache != lexicalRuntimeCache {
                lines.append("(allow file-read* (subpath \(resolvedRuntimeCache)))")
                lines.append("(allow file-write* (subpath \(resolvedRuntimeCache)))")
            }
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