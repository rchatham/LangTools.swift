//
//  WorkerProvisioning.swift
//  AgentDeploy
//
//  What goes on a worker machine. The first-boot script holds no secrets, because
//  droplet user data is readable through the metadata service and kept by
//  DigitalOcean; API keys and registry credentials are uploaded afterwards over SSH.
//

import Foundation

public enum WorkerProvisioning {
    public static let configDirectory = "/etc/langtools-agent"
    public static let envFile = "\(configDirectory)/env"
    public static let workerConfigFile = "\(configDirectory)/worker.conf"
    public static let dockerConfigDirectory = "\(configDirectory)/docker"
    public static let spoolDirectory = "/var/lib/langtools-agent"
    public static let serviceName = "langtools-agent"
    public static let containerName = "langtools-agent"
    /// The image's `agent` user, which must own the spool.
    public static let containerUID = 10001

    /// Installs Docker and the worker service. The service waits for the config that
    /// `configure` uploads, so nothing runs until the keys are in place.
    public static var userDataScript: String {
        """
        #!/bin/bash
        # langtools-agent worker first-boot setup. Contains no secrets.
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        # unattended-upgrades often holds the apt lock on a fresh droplet; wait for it.
        apt-get -o DPkg::Lock::Timeout=600 update
        apt-get -o DPkg::Lock::Timeout=600 install -y --no-install-recommends docker.io
        systemctl enable --now docker

        install -d -m 0700 \(configDirectory) \(dockerConfigDirectory)
        install -d -m 0700 -o \(containerUID) -g \(containerUID) \(spoolDirectory)

        cat > /etc/systemd/system/\(serviceName).service <<'UNIT'
        \(serviceUnit)
        UNIT
        systemctl daemon-reload
        systemctl enable \(serviceName).service

        # Only SSH is reachable from outside; the worker opens no ports.
        if command -v ufw >/dev/null; then
            ufw allow OpenSSH
            ufw --force enable
        fi
        """
    }

    public static var serviceUnit: String {
        """
        [Unit]
        Description=LangTools agent worker
        After=docker.service network-online.target
        Wants=network-online.target
        Requires=docker.service
        ConditionPathExists=\(envFile)
        ConditionPathExists=\(workerConfigFile)

        [Service]
        EnvironmentFile=\(workerConfigFile)
        ExecStartPre=-/usr/bin/docker rm -f \(containerName)
        ExecStartPre=-/usr/bin/docker --config \(dockerConfigDirectory) pull ${IMAGE}
        ExecStart=/usr/bin/docker run --rm --name \(containerName) \\
            --env-file \(envFile) \\
            -v \(spoolDirectory):/spool \\
            --read-only --tmpfs /tmp \\
            --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 \\
            ${IMAGE} worker --spool /spool --concurrency ${CONCURRENCY}
        # Running jobs get up to five minutes to finish; unfinished ones are retried on restart.
        ExecStop=/usr/bin/docker stop -t 300 \(containerName)
        TimeoutStopSec=330
        Restart=always
        RestartSec=5

        [Install]
        WantedBy=multi-user.target
        """
    }

    public struct WorkerConfig: Equatable {
        public var image: String
        public var concurrency: Int

        public init(image: String, concurrency: Int) {
            self.image = image
            self.concurrency = concurrency
        }

        public func validate() throws {
            // The image is substituted into the unit's command line.
            guard !image.isEmpty, image.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "./:-_@".unicodeScalars.contains($0)) }) else {
                throw DeployError.invalidArgument("Image reference '\(image)' contains characters an image name can't have.")
            }
            guard (1...64).contains(concurrency) else { throw DeployError.invalidArgument("Concurrency must be between 1 and 64.") }
        }

        var fileContents: String { "IMAGE=\(image)\nCONCURRENCY=\(concurrency)\n" }

        static func parse(_ contents: String) -> (image: String?, concurrency: Int?) {
            var image: String?, concurrency: Int?
            for line in contents.split(separator: "\n") {
                let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                if pair[0] == "IMAGE" { image = pair[1] }
                if pair[0] == "CONCURRENCY" { concurrency = Int(pair[1]) }
            }
            return (image, concurrency)
        }
    }

    /// Checks a Docker `--env-file`: `KEY=value` lines and `#` comments. Docker keeps
    /// quotes as part of the value, which is a common way to break an API key, so
    /// quoted values are reported rather than passed through.
    public static func validateEnvFile(_ contents: String) throws -> [String] {
        var keys: [String] = []
        for (index, rawLine) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, let first = pair[0].unicodeScalars.first, !CharacterSet.decimalDigits.contains(first),
                  pair[0].unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") })
            else { throw DeployError.invalidArgument("Env file line \(index + 1) is not KEY=value.") }
            let value = pair[1]
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                throw DeployError.invalidArgument("Env file line \(index + 1): remove the quotes around \(pair[0])'s value; Docker would keep them as part of it.")
            }
            keys.append(pair[0])
        }
        return keys
    }
}

/// Runs commands on a worker over SSH as root.
public struct WorkerConnection {
    public var host: String
    public var user: String
    /// Host keys are pinned here on first connection.
    public var knownHostsFile: URL
    public var identityFile: String?
    public var runner: CommandRunner

    public init(host: String, user: String = "root", knownHostsFile: URL, identityFile: String? = nil, runner: CommandRunner) {
        self.host = host
        self.user = user
        self.knownHostsFile = knownHostsFile
        self.identityFile = identityFile
        self.runner = runner
    }

    var sshArguments: [String] {
        var arguments = [
            "-o", "BatchMode=yes",
            // A new droplet's host key can't be known in advance; it is trusted on first use and pinned after.
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsFile.path)",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
        ]
        if let identityFile { arguments += ["-i", identityFile] }
        return arguments + ["\(user)@\(host)"]
    }

    /// Runs `command` through the remote shell. Every value spliced into it must be quoted with `shellQuote`.
    @discardableResult
    public func run(_ command: String, stdin: Data? = nil) async throws -> CommandOutput {
        try await runner.checked("ssh", sshArguments + ["--", command], stdin: stdin)
    }

    func attempt(_ command: String) async throws -> CommandOutput {
        try await runner.run("ssh", sshArguments + ["--", command], stdin: nil)
    }

    /// Writes `contents` to `path` with mode 0600, replacing it atomically.
    public func upload(_ contents: Data, to path: String) async throws {
        let quoted = shellQuote(path), staged = shellQuote(path + ".new")
        try await run("umask 077 && cat > \(staged) && mv -f \(staged) \(quoted)", stdin: contents)
    }
}

/// Quotes `value` for a POSIX shell.
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
