//
//  AgentDeployCommand.swift
//  AgentDeploy
//
//  The `langtools-agent-deploy` command line, over `AgentFleet`.
//

import Foundation
import AgentRuntime

public struct AgentDeployCommand {
    public var fleet: AgentFleet
    public var environment: [String: String]
    public var readFile: (String) throws -> Data
    public var standardInput: () -> Data
    public var standardOutput: (String) -> Void
    public var standardError: (String) -> Void

    public init(
        fleet: AgentFleet,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readFile: @escaping (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) },
        standardInput: @escaping () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
        standardOutput: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        standardError: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.fleet = fleet
        self.environment = environment
        self.readFile = readFile
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public static let usage = """
        Usage: langtools-agent-deploy <command> [options]

        A worker is a langtools-agent container on a host. A host is any machine with
        Docker: this one ("local", always available), a server you can SSH into, or a
        machine created with a provider such as DigitalOcean.

        Workers:
          create <worker>          Start a worker.
              --image <ref>        The langtools-agent image (required).
              --host <host>        Default: local.
              --env-file <path>    KEY=value file with provider API keys and LANGTOOLS_WEBHOOK_SECRET.
              --owner <owner>      Isolate the worker for one owner: its own container, keys and queue.
              --concurrency <n>    Jobs at once. Default 2.
              --network <name>     Docker network to attach to. Default: Docker's default.
              --registry-config <path>
                                   Docker config.json for pulling from a private registry.
              --pull               Pull the image even if the host already has it.
          configure <worker>       Recreate a worker, keeping its queue and results.
              --image <ref>  --concurrency <n>  --env-file <path>  --registry-config <path>  --pull
          submit <worker> <spec.json | ->
                                   Queue a spec; prints the run ID.
              --webhook <url>  --run-id <id>  --owner <owner>
              --wait               Wait for the result and print it.
              --timeout <s>        With --wait, give up after this many seconds.
          status <worker> <run-id> Print a job's state, and its result once done.
          logs <worker>            Print the worker's recent log. --lines <n>, default 200.
          list                     List workers on every host.
          destroy <worker> --force Remove the worker and its queue and results. --keep-results keeps them.

        Hosts:
          host add <host> --ssh <user@address>
                                   Register a machine that already has Docker.
              --port <n>  --identity <key path>
              --owner <owner>      Dedicate the host to one owner.
          host create <host> --provider digitalocean
                                   Create a machine and install Docker on it.
              --region <slug>  --size <slug>  --ssh-key <id> (repeatable)  --owner <owner>
          host list                List hosts.
          host check <host>        Check that Docker is reachable on the host.
          host remove <host>       Forget a host. The machine is left as it is.
          host destroy <host> --force
                                   Delete a provider-created machine and everything on it.
          host setup-script        Print the script that installs Docker on a fresh Ubuntu machine.

        LANGTOOLS_WEBHOOK_SECRET in this environment, if set, signs a submitted job's
        webhook instead of the worker's secret. The registry of hosts and workers is in
        ~/.config/langtools-agent/fleet.json.
        """

    public func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            standardError(Self.usage)
            return 2
        }
        var options = Array(arguments.dropFirst())
        do {
            switch command {
            case "create": try await create(&options)
            case "configure": try await configure(&options)
            case "submit": return try await submit(&options)
            case "status": return try await status(&options)
            case "logs":
                let lines = try take("--lines", from: &options).map { try positive($0, "--lines") } ?? 200
                standardOutput(try await fleet.logs(of: try single(&options, "logs takes one worker name."), lines: lines).trimmingCharacters(in: .newlines))
            case "list": try await list(&options)
            case "destroy": return try await destroy(&options)
            case "host": return try await host(&options)
            case "help", "--help", "-h": standardOutput(Self.usage)
            default:
                standardError("error: Unknown command '\(command)'.\n\n\(Self.usage)")
                return 2
            }
            return 0
        } catch let error as DeployError {
            standardError("error: \(error.localizedDescription)")
            if case .invalidArgument = error { return 2 }
            return 1
        } catch {
            standardError("error: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - Workers

    private func create(_ options: inout [String]) async throws {
        let image = try required("--image", from: &options)
        let host = try take("--host", from: &options) ?? HostRecord.local.name
        let envPath = try take("--env-file", from: &options)
        let owner = try take("--owner", from: &options)
        let concurrency = try take("--concurrency", from: &options).map { try positive($0, "--concurrency") } ?? 2
        let network = try take("--network", from: &options)
        let registryConfig = try take("--registry-config", from: &options).map(read)
        let pull = take(flag: "--pull", from: &options)
        let name = try single(&options, "create takes one worker name.")

        let configuration = WorkerContainer.Configuration(name: name, image: image, owner: owner, concurrency: concurrency, network: network)
        try configuration.validate()
        let env = try envPath.map(loadEnvFile) ?? {
            standardError("warning: no --env-file; the worker has no API keys, so only providers that need none (such as a local Ollama) will work.")
            return Data()
        }()
        try await fleet.createWorker(configuration, on: host, env: env, registryConfig: registryConfig, pull: pull)
        standardOutput("\(name)\t\(host)\tready")
    }

    private func configure(_ options: inout [String]) async throws {
        let image = try take("--image", from: &options)
        let concurrency = try take("--concurrency", from: &options).map { try positive($0, "--concurrency") }
        let env = try take("--env-file", from: &options).map(loadEnvFile)
        let registryConfig = try take("--registry-config", from: &options).map(read)
        let pull = take(flag: "--pull", from: &options)
        let name = try single(&options, "configure takes one worker name.")
        if let image, !WorkerContainer.Configuration.isImageReference(image) { throw DeployError.invalidArgument("Image reference '\(image)' contains characters an image name can't have.") }
        try await fleet.configureWorker(name, image: image, concurrency: concurrency, env: env, registryConfig: registryConfig, pull: pull)
        standardOutput("\(name)\tready")
    }

    private func submit(_ options: inout [String]) async throws -> Int32 {
        let webhook = try take("--webhook", from: &options)
        let runID = try take("--run-id", from: &options)
        let owner = try take("--owner", from: &options)
        let wait = take(flag: "--wait", from: &options)
        let timeout = try take("--timeout", from: &options).map { try positive($0, "--timeout") }
        guard options.count == 2 else { throw DeployError.invalidArgument("submit takes a worker name and a spec path.") }
        let (name, specPath) = (options[0], options[1])
        if let owner { try WorkerNames.validate(owner: owner) }

        let data = specPath == "-" ? standardInput() : try read(specPath)
        var job = AgentJob(spec: try AgentSpec.decode(from: data), webhookSecret: environment[AgentRuntimeCommand.webhookSecretVariable], owner: owner)
        if let runID { job.runID = runID }
        if let webhook {
            guard let url = URL(string: webhook), url.host != nil else { throw DeployError.invalidArgument("Invalid webhook URL: \(webhook)") }
            job.webhookURL = url
        }
        try await fleet.submit(job, to: name)
        guard wait else {
            standardOutput(Self.json(["runID": job.runID, "state": AgentSpool.State.queued.rawValue]))
            return 0
        }
        let result = try await fleet.waitForResult(of: job.runID, on: name, timeout: timeout.map(TimeInterval.init))
        standardOutput(String(decoding: try result.encoded(), as: UTF8.self))
        return result.status == .completed ? 0 : 1
    }

    private func status(_ options: inout [String]) async throws -> Int32 {
        guard options.count == 2 else { throw DeployError.invalidArgument("status takes a worker name and a run ID.") }
        let status = try await fleet.status(of: options[1], on: options[0])
        var fields: [String: Any] = ["runID": status.runID, "state": status.state.rawValue]
        if let result = status.result { fields["result"] = try JSONSerialization.jsonObject(with: result.encoded(prettyPrinted: false)) }
        standardOutput(Self.json(fields))
        return status.state == .unknown ? 1 : 0
    }

    private func list(_ options: inout [String]) async throws {
        guard options.isEmpty else { throw DeployError.invalidArgument("list takes no arguments.") }
        standardOutput(["NAME", "HOST", "OWNER", "STATE", "IMAGE", "CONCURRENCY"].joined(separator: "\t"))
        for worker in try await fleet.listWorkers() {
            standardOutput([worker.name, worker.host, worker.owner ?? "-", worker.state, worker.image ?? "-", worker.concurrency.map(String.init) ?? "-"].joined(separator: "\t"))
        }
    }

    private func destroy(_ options: inout [String]) async throws -> Int32 {
        let force = take(flag: "--force", from: &options)
        let keepResults = take(flag: "--keep-results", from: &options)
        let name = try single(&options, "destroy takes one worker name.")
        guard force else {
            standardError("This removes worker '\(name)'\(keepResults ? "" : " with its queue and results"). Run again with --force to confirm.")
            return 2
        }
        try await fleet.destroyWorker(name, keepResults: keepResults)
        standardOutput("\(name)\tdestroyed")
        return 0
    }

    // MARK: - Hosts

    private func host(_ options: inout [String]) async throws -> Int32 {
        guard let subcommand = options.first else { throw DeployError.invalidArgument("host needs a subcommand: add, create, list, check, remove, destroy or setup-script.") }
        options.removeFirst()
        switch subcommand {
        case "add":
            let address = try required("--ssh", from: &options)
            let port = try take("--port", from: &options).map { try positive($0, "--port") }
            let identity = try take("--identity", from: &options)
            let owner = try take("--owner", from: &options)
            let name = try single(&options, "host add takes one host name.")
            try await fleet.addHost(HostRecord(name: name, kind: .ssh, address: address, port: port, identityFile: identity, owner: owner))
            standardOutput("\(name)\t\(address)\tready")
        case "create":
            let provider = try required("--provider", from: &options)
            let region = try take("--region", from: &options)
            let size = try take("--size", from: &options)
            let owner = try take("--owner", from: &options)
            var sshKeys: [String] = []
            while let key = try take("--ssh-key", from: &options) { sshKeys.append(key) }
            let name = try single(&options, "host create takes one host name.")
            let host = try await fleet.createHost(name: name, provider: provider, owner: owner, region: region, size: size, sshKeys: sshKeys)
            standardOutput("\(name)\t\(host.address ?? "-")\tready")
        case "list":
            guard options.isEmpty else { throw DeployError.invalidArgument("host list takes no arguments.") }
            standardOutput(["NAME", "KIND", "ADDRESS", "OWNER", "PROVIDER"].joined(separator: "\t"))
            for host in try fleet.hosts() {
                standardOutput([host.name, host.kind.rawValue, host.address.map { a in host.port.map { "\(a):\($0)" } ?? a } ?? "-", host.owner ?? "-", host.provider ?? "-"].joined(separator: "\t"))
            }
        case "check":
            let name = try single(&options, "host check takes one host name.")
            let version = try await fleet.checkHost(try fleet.store.load().host(named: name))
            standardOutput("\(name)\tdocker \(version)")
        case "remove":
            try fleet.removeHost(try single(&options, "host remove takes one host name."))
        case "destroy":
            let force = take(flag: "--force", from: &options)
            let name = try single(&options, "host destroy takes one host name.")
            guard force else {
                standardError("This deletes host '\(name)''s machine and every worker on it. Run again with --force to confirm.")
                return 2
            }
            try await fleet.destroyHost(name)
            standardOutput("\(name)\tdestroyed")
        case "setup-script":
            standardOutput(HostBootstrap.script)
        default:
            throw DeployError.invalidArgument("Unknown host subcommand '\(subcommand)'.")
        }
        return 0
    }

    // MARK: - Helpers

    private func read(_ path: String) throws -> Data {
        do { return try readFile(path) } catch { throw DeployError.invalidArgument("Could not read \(path): \(error.localizedDescription)") }
    }

    private func loadEnvFile(_ path: String) throws -> Data {
        let data = try read(path)
        let keys = try WorkerContainer.validateEnvFile(String(decoding: data, as: UTF8.self))
        if !keys.contains(where: { $0.hasSuffix("_API_KEY") }) {
            standardError("warning: \(path) sets no *_API_KEY variable, so only providers that need no key will work.")
        }
        if !keys.contains(AgentRuntimeCommand.webhookSecretVariable) {
            standardError("warning: \(path) has no \(AgentRuntimeCommand.webhookSecretVariable); webhook deliveries will be unsigned unless each job brings a secret.")
        }
        return data
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func take(_ option: String, from options: inout [String]) throws -> String? {
        guard let index = options.firstIndex(of: option) else { return nil }
        guard options.indices.contains(index + 1) else { throw DeployError.invalidArgument("\(option) needs a value.") }
        let value = options[index + 1]
        options.removeSubrange(index...(index + 1))
        return value
    }

    private func take(flag: String, from options: inout [String]) -> Bool {
        guard let index = options.firstIndex(of: flag) else { return false }
        options.remove(at: index)
        return true
    }

    private func required(_ option: String, from options: inout [String]) throws -> String {
        guard let value = try take(option, from: &options) else { throw DeployError.invalidArgument("\(option) is required.") }
        return value
    }

    private func single(_ options: inout [String], _ message: String) throws -> String {
        guard options.count == 1 else { throw DeployError.invalidArgument(message) }
        return options[0]
    }

    private func positive(_ value: String, _ option: String) throws -> Int {
        guard let n = Int(value), n > 0 else { throw DeployError.invalidArgument("\(option) must be a positive integer.") }
        return n
    }
}
