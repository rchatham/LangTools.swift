//
//  WorkerContainer.swift
//  AgentDeploy
//
//  A worker is one langtools-agent container on a host with Docker. Docker restarts it
//  after a crash or reboot (`--restart unless-stopped`), so the same setup works on a
//  laptop, a server and a cloud machine, with no service manager involved.
//
//  On the host, each worker has:
//      container  langtools-agent-<name>, labelled with the worker's name and owner
//      volume     langtools-agent-<name>, its queue and results, mounted at /spool
//      directory  ~/.config/langtools-agent/workers/<name>/ with the env file (0600)
//                 and, for private registries, docker/config.json
//

import Foundation

public enum WorkerContainer {
    static let workerLabel = "dev.langtools.agent.worker"
    static let ownerLabel = "dev.langtools.agent.owner"
    static let concurrencyLabel = "dev.langtools.agent.concurrency"
    static let networkLabel = "dev.langtools.agent.network"

    public static func containerName(_ worker: String) -> String { "langtools-agent-\(worker)" }
    public static func volumeName(_ worker: String) -> String { "langtools-agent-\(worker)" }
    static func configDirectory(_ worker: String) -> HostPath { .home(".config", "langtools-agent", "workers", worker, "") }
    static func envFile(_ worker: String) -> HostPath { .home(".config", "langtools-agent", "workers", worker, "env") }
    static func registryConfig(_ worker: String) -> HostPath { .home(".config", "langtools-agent", "workers", worker, "docker", "config.json") }

    public struct Configuration: Equatable {
        public var name: String
        public var image: String
        public var owner: String?
        public var concurrency: Int
        /// A Docker network to attach to; nil uses Docker's default.
        public var network: String?

        public init(name: String, image: String, owner: String? = nil, concurrency: Int = 2, network: String? = nil) {
            self.name = name
            self.image = image
            self.owner = owner
            self.concurrency = concurrency
            self.network = network
        }

        public func validate() throws {
            try WorkerNames.validate(name: name)
            if let owner { try WorkerNames.validate(owner: owner) }
            // Both are spliced into a shell command line.
            guard Self.isImageReference(image) else { throw DeployError.invalidArgument("Image reference '\(image)' contains characters an image name can't have.") }
            if let network, !network.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }) {
                throw DeployError.invalidArgument("Network name '\(network)' must be letters, digits, '.', '_' or '-'.")
            }
            guard (1...64).contains(concurrency) else { throw DeployError.invalidArgument("Concurrency must be between 1 and 64.") }
        }

        static func isImageReference(_ image: String) -> Bool {
            !image.isEmpty && !image.hasPrefix("-") && image.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "./:-_@".unicodeScalars.contains($0)) }
        }
    }

    /// Starts the image only after a pull when it isn't already on the host, so a locally
    /// built image works without a registry. `pull` forces a fresh pull.
    static func pullCommand(_ configuration: Configuration, usesRegistryConfig: Bool, pull: Bool) -> String {
        let image = shellQuote(configuration.image)
        let dockerPull = usesRegistryConfig
            ? "docker --config \(registryConfig(configuration.name).directory) pull \(image)"
            : "docker pull \(image)"
        return pull ? dockerPull : "docker image inspect \(image) >/dev/null 2>&1 || \(dockerPull)"
    }

    static func runCommand(_ configuration: Configuration) -> String {
        let name = configuration.name
        var arguments = [
            "docker run -d",
            "--name \(shellQuote(containerName(name)))",
            "--restart unless-stopped",
            // Running jobs get five minutes to finish on `docker stop`; unfinished ones are retried on restart.
            "--stop-timeout 300",
            "--label \(shellQuote("\(workerLabel)=\(name)"))",
            "--label \(shellQuote("\(concurrencyLabel)=\(configuration.concurrency)"))",
        ]
        if let owner = configuration.owner { arguments.append("--label \(shellQuote("\(ownerLabel)=\(owner)"))") }
        if let network = configuration.network {
            arguments.append("--label \(shellQuote("\(networkLabel)=\(network)"))")
            arguments.append("--network \(shellQuote(network))")
        }
        arguments += [
            "--env-file \(envFile(name))",
            "-v \(shellQuote(volumeName(name))):/spool",
            "--read-only --tmpfs /tmp",
            "--cap-drop ALL --security-opt no-new-privileges --pids-limit 512",
            shellQuote(configuration.image),
            "worker --spool /spool --concurrency \(configuration.concurrency)",
        ]
        return arguments.joined(separator: " ")
    }

    /// Stops the worker, letting running jobs finish, and removes the container. The volume is kept.
    static func removeContainerCommand(_ name: String) -> String {
        let container = shellQuote(containerName(name))
        return "if docker container inspect \(container) >/dev/null 2>&1; then docker stop \(container) >/dev/null && docker rm \(container) >/dev/null; fi"
    }

    static func exec(_ name: String, _ arguments: String, interactive: Bool = false) -> String {
        "docker exec\(interactive ? " -i" : "") \(shellQuote(containerName(name))) langtools-agent \(arguments)"
    }

    /// Prints a JSON array describing every worker container on the host.
    static let inspectAllCommand = "ids=$(docker ps -aq --filter label=\(workerLabel)); if [ -z \"$ids\" ]; then echo '[]'; else docker inspect $ids; fi"

    /// A worker container as found on a host.
    public struct Found: Equatable {
        public var name: String
        public var owner: String?
        public var image: String
        public var state: String
        public var concurrency: Int?
        public var network: String?
    }

    static func parseInspect(_ data: Data) throws -> [Found] {
        struct Container: Decodable {
            struct Config: Decodable { var Image: String?; var Labels: [String: String]? }
            struct State: Decodable { var Status: String? }
            var Config: Config?
            var State: State?
        }
        let containers: [Container]
        do { containers = try JSONDecoder().decode([Container].self, from: data) }
        catch { throw DeployError.unexpectedOutput("Could not read `docker inspect` output: \(error)") }
        return containers.compactMap { container in
            let labels = container.Config?.Labels ?? [:]
            guard let name = labels[workerLabel] else { return nil }
            return Found(name: name, owner: labels[ownerLabel], image: container.Config?.Image ?? "?", state: container.State?.Status ?? "unknown",
                         concurrency: labels[concurrencyLabel].flatMap(Int.init), network: labels[networkLabel])
        }.sorted { $0.name < $1.name }
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

/// Prepares a fresh Ubuntu machine to be a host: installs Docker and turns on the
/// firewall with only SSH allowed. Holds no secrets, because cloud user data is
/// readable from inside the machine and kept by the provider.
public enum HostBootstrap {
    public static var script: String {
        """
        #!/bin/bash
        # langtools-agent host setup: Docker, with a firewall allowing only SSH. Contains no secrets.
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        # unattended-upgrades often holds the apt lock on a fresh machine; wait for it.
        apt-get -o DPkg::Lock::Timeout=600 update
        apt-get -o DPkg::Lock::Timeout=600 install -y --no-install-recommends docker.io
        # Docker starts at boot, and with it every worker (--restart unless-stopped).
        systemctl enable --now docker

        if command -v ufw >/dev/null; then
            ufw allow OpenSSH
            ufw --force enable
        fi
        """
    }
}

public enum WorkerNames {
    /// Host and worker names: lowercase letters, digits and `-`, up to 40 characters.
    public static func validate(name: String) throws {
        guard (1...40).contains(name.count), !name.hasPrefix("-"), !name.hasSuffix("-"),
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
        else { throw DeployError.invalidArgument("Name '\(name)' must be 1-40 lowercase letters, digits or '-', not starting or ending with '-'.") }
    }

    /// Owners go into labels and tags: letters, digits, `_` and `-`, up to 64 characters.
    public static func validate(owner: String) throws {
        guard (1...64).contains(owner.count),
              owner.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") })
        else { throw DeployError.invalidArgument("Owner '\(owner)' must be 1-64 letters, digits, '_' or '-'.") }
    }
}
