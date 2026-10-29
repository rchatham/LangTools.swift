//
//  HostShell.swift
//  AgentDeploy
//
//  Runs shell command lines on a host: this machine directly, or another one over SSH.
//  Everything the deploy tool does to a host goes through one of these, so a worker on
//  a laptop and one on a cloud server are managed the same way.
//

import Foundation

public protocol HostShell {
    /// A short description for messages, such as `local` or `reid@10.0.0.5`.
    var description: String { get }
    /// Runs `command` with `/bin/sh`. Every value spliced into it must be quoted with `shellQuote`.
    func attempt(_ command: String, stdin: Data?) async throws -> CommandOutput
}

extension HostShell {
    public func attempt(_ command: String) async throws -> CommandOutput {
        try await attempt(command, stdin: nil)
    }

    /// Runs `command` and throws when it exits non-zero.
    @discardableResult
    public func run(_ command: String, stdin: Data? = nil) async throws -> CommandOutput {
        let output = try await attempt(command, stdin: stdin)
        guard output.status == 0 else {
            throw DeployError.commandFailed(executable: "\(description): \(command.prefix(60))", status: output.status, message: output.stderrString)
        }
        return output
    }

    /// Writes `contents` to `path` with mode 0600, creating its directory with mode 0700
    /// and replacing the file atomically. `path` is a shell word, so it may use `"$HOME"`.
    public func upload(_ contents: Data, to path: HostPath) async throws {
        try await run("umask 077 && mkdir -p \(path.directory) && cat > \(path.staged) && mv -f \(path.staged) \(path)", stdin: contents)
    }
}

/// A path on a host, written as a shell word. Paths under the user's home use `"$HOME"`
/// so they work for root on a droplet and for a regular user on a laptop alike.
public struct HostPath: CustomStringConvertible, Equatable {
    /// The shell word, such as `"$HOME/.config/langtools-agent/workers/alice/env"`.
    public let description: String
    let directory: String
    let staged: String

    /// `components` must already be safe in double quotes: letters, digits, `.`, `_` and `-`.
    static func home(_ components: String...) -> HostPath {
        let relative = components.joined(separator: "/")
        let directory = components.dropLast().joined(separator: "/")
        return HostPath(description: "\"$HOME/\(relative)\"", directory: "\"$HOME/\(directory)\"", staged: "\"$HOME/\(relative).new\"")
    }
}

/// This machine.
public struct LocalShell: HostShell {
    public var runner: CommandRunner
    public var description: String { "local" }

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    public func attempt(_ command: String, stdin: Data?) async throws -> CommandOutput {
        try await runner.run("/bin/sh", ["-c", command], stdin: stdin)
    }
}

/// Another machine, over SSH.
public struct SSHShell: HostShell {
    /// `user@host` or `host`.
    public var address: String
    public var port: Int?
    public var identityFile: String?
    /// Host keys are pinned here on first connection.
    public var knownHostsFile: URL
    public var runner: CommandRunner

    public init(address: String, port: Int? = nil, identityFile: String? = nil, knownHostsFile: URL, runner: CommandRunner) {
        self.address = address
        self.port = port
        self.identityFile = identityFile
        self.knownHostsFile = knownHostsFile
        self.runner = runner
    }

    public var description: String { port.map { "\(address):\($0)" } ?? address }

    var sshArguments: [String] {
        var arguments = [
            "-o", "BatchMode=yes",
            // A new machine's host key can't be known in advance; it is trusted on first use and pinned after.
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsFile.path)",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
        ]
        if let port { arguments += ["-p", String(port)] }
        if let identityFile { arguments += ["-i", identityFile] }
        return arguments + [address]
    }

    public func attempt(_ command: String, stdin: Data?) async throws -> CommandOutput {
        try FileManager.default.createDirectory(at: knownHostsFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = try await runner.run("ssh", sshArguments + ["--", command], stdin: stdin)
        if output.status == 127, output.stderrString.hasPrefix("/usr/bin/env:") {
            throw DeployError.invalidArgument("Could not find `ssh`. Install OpenSSH and make sure it is on PATH.")
        }
        return output
    }
}

/// Quotes `value` for a POSIX shell.
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
