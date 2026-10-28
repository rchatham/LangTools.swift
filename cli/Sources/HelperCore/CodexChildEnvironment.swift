import Foundation

/// Constructs the exact environment inherited by contained Codex processes.
///
/// Only compatibility-critical, non-secret values are copied from the parent.
/// Provider credentials, proxy credentials, agent sockets, and unrelated app
/// configuration are intentionally omitted. Codex account credentials are read
/// from the explicitly granted Codex home instead.
enum CodexChildEnvironment {
    static let inheritedKeys: Set<String> = [
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LOGNAME",
        "PATH",
        "SHELL",
        "TERM",
        "TZ",
        "USER",
    ]

    static func make(
        parent: [String: String],
        codexHome: URL,
        temporaryDirectory: URL,
        disableAppServerRemoteControl: Bool = false
    ) -> [String: String] {
        var child = parent.filter { key, value in
            inheritedKeys.contains(key) && value.isEmpty == false
        }
        child["CODEX_HOME"] = codexHome.path
        child["TMPDIR"] = temporaryDirectory.path
        child["TMP"] = temporaryDirectory.path
        child["TEMP"] = temporaryDirectory.path
        if disableAppServerRemoteControl {
            child["CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED"] = "1"
        }
        return child
    }
}

/// Creates an owner-only temporary directory for one contained Codex process.
/// The caller owns cleanup.
enum CodexProcessTemporaryDirectory {
    private static let permissions = NSNumber(value: Int16(0o700))

    static func create(
        inside parent: URL? = nil,
        prefix: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let parentURL = parent ?? fileManager.temporaryDirectory
        let directory = parentURL.appendingPathComponent(
            "langtools-codex-\(prefix)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: permissions]
        )
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: directory.path
        )
        return directory.standardizedFileURL.resolvingSymlinksInPath()
    }
}
