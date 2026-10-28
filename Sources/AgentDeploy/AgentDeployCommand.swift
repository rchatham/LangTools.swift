//
//  AgentDeployCommand.swift
//  AgentDeploy
//
//  The `langtools-agent-deploy` command line: creates workers, uploads their keys,
//  submits jobs and reads results.
//

import Foundation
import AgentRuntime

public struct AgentDeployCommand {
    public var compute: ComputeProvider
    public var runner: CommandRunner
    public var environment: [String: String]
    public var knownHostsFile: URL
    public var readFile: (String) throws -> Data
    public var standardInput: () -> Data
    public var standardOutput: (String) -> Void
    public var standardError: (String) -> Void
    var sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    /// Time allowed for a new droplet to accept SSH and finish first-boot setup.
    var bootTimeout: TimeInterval = 600
    /// Time allowed for the service to pull the image and start.
    var startTimeout: TimeInterval = 600

    public init(
        compute: ComputeProvider,
        runner: CommandRunner,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        knownHostsFile: URL? = nil,
        readFile: @escaping (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) },
        standardInput: @escaping () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
        standardOutput: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        standardError: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.compute = compute
        self.runner = runner
        self.environment = environment
        self.knownHostsFile = knownHostsFile ?? Self.defaultKnownHostsFile(environment: environment)
        self.readFile = readFile
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public static let usage = """
        Usage: langtools-agent-deploy <command> [options]

        Workers run the langtools-agent image on DigitalOcean droplets, managed with doctl.
        A shared worker takes anyone's jobs; an isolated worker (--owner) has its own
        droplet, API keys and queue, and only takes jobs submitted with its owner.

        Commands:
          create <name>            Create a worker and start it.
              --image <ref>        The langtools-agent image to run (required).
              --env-file <path>    KEY=value file with provider API keys and LANGTOOLS_WEBHOOK_SECRET (required).
              --owner <owner>      Make the worker isolated for this owner.
              --region <slug>      Default nyc3.
              --size <slug>        Default s-1vcpu-1gb.
              --ssh-key <id>       SSH key ID or fingerprint; repeat for more. Default: every key on the account.
              --concurrency <n>    Jobs to run at once. Default 2.
          configure <name>         Replace a worker's keys, image or concurrency, then restart it.
              --env-file <path>  --image <ref>  --concurrency <n>
          submit <name> <spec.json | ->
                                   Queue a spec on a worker; prints the run ID.
              --webhook <url>      Where the worker POSTs the result.
              --run-id <id>        Default: a new UUID.
              --owner <owner>      Required for an isolated worker.
          status <name> <run-id>   Print a job's state, and its result once done.
          logs <name>              Print the worker's recent log.
              --lines <n>          Default 200.
          list                     List workers.
          destroy <name> --force   Delete the worker's droplet and everything on it.
          user-data                Print the first-boot script a new droplet runs.

        LANGTOOLS_WEBHOOK_SECRET in this environment, if set, signs that job's webhook
        instead of the worker's secret. SSH host keys are pinned in
        ~/.config/langtools-agent/known_hosts.
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
            case "submit": try await submit(&options)
            case "status": return try await status(&options)
            case "logs": try await logs(&options)
            case "list": try await list(&options)
            case "destroy": return try await destroy(&options)
            case "user-data": standardOutput(WorkerProvisioning.userDataScript)
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

    // MARK: - Commands

    private func create(_ options: inout [String]) async throws {
        let image = try required("--image", from: &options)
        let envPath = try required("--env-file", from: &options)
        let owner = try take("--owner", from: &options)
        let region = try take("--region", from: &options) ?? "nyc3"
        let size = try take("--size", from: &options) ?? "s-1vcpu-1gb"
        let concurrency = try take("--concurrency", from: &options).map(parseConcurrency) ?? 2
        var sshKeys: [String] = []
        while let key = try take("--ssh-key", from: &options) { sshKeys.append(key) }
        let name = try single(&options, "create takes one worker name.")

        // Everything that can be checked locally is checked before a droplet costs money.
        try WorkerNames.validate(name: name)
        if let owner { try WorkerNames.validate(owner: owner) }
        let config = WorkerProvisioning.WorkerConfig(image: image, concurrency: concurrency)
        try config.validate()
        let env = try loadEnvFile(envPath)
        if try await compute.workers().contains(where: { $0.name == name }) { throw DeployError.workerExists(name) }

        standardError("Creating \(owner.map { "isolated worker for \($0)" } ?? "shared worker") '\(name)' (\(size) in \(region))...")
        let worker = try await compute.createWorker(WorkerRequest(name: name, owner: owner, region: region, size: size, sshKeys: sshKeys, userData: WorkerProvisioning.userDataScript))
        do {
            let connection = try connection(to: worker)
            await forgetHostKey(of: worker)  // A reused IP may have an old droplet's key pinned.
            standardError("Droplet \(worker.id) is at \(connection.host); waiting for first-boot setup...")
            try await waitForBoot(connection)
            try await install(config: config, env: env, on: connection)
        } catch {
            standardError("The droplet was created but setup did not finish. Fix the problem and run `langtools-agent-deploy configure \(name) ...`, or remove it with `langtools-agent-deploy destroy \(name) --force`.")
            throw error
        }
        standardOutput("\(name)\t\(worker.publicIPv4 ?? "-")\tready")
    }

    private func configure(_ options: inout [String]) async throws {
        let envPath = try take("--env-file", from: &options)
        let image = try take("--image", from: &options)
        let concurrency = try take("--concurrency", from: &options).map(parseConcurrency)
        let name = try single(&options, "configure takes one worker name.")
        guard envPath != nil || image != nil || concurrency != nil else { throw DeployError.invalidArgument("Pass --env-file, --image or --concurrency.") }
        let env = try envPath.map(loadEnvFile)

        let connection = try connection(to: try await compute.worker(named: name))
        let current = WorkerProvisioning.WorkerConfig.parse(try await connection.attempt("cat \(WorkerProvisioning.workerConfigFile)").stdoutString)
        guard let resolvedImage = image ?? current.image else { throw DeployError.invalidArgument("The worker has no image configured yet; pass --image.") }
        let config = WorkerProvisioning.WorkerConfig(image: resolvedImage, concurrency: concurrency ?? current.concurrency ?? 2)
        try config.validate()
        if env == nil, try await connection.attempt("test -f \(WorkerProvisioning.envFile)").status != 0 {
            throw DeployError.invalidArgument("The worker has no keys yet; pass --env-file.")
        }
        try await install(config: config, env: env, on: connection)
        standardOutput("\(name)\tready")
    }

    private func submit(_ options: inout [String]) async throws {
        let webhook = try take("--webhook", from: &options)
        let runID = try take("--run-id", from: &options)
        let owner = try take("--owner", from: &options)
        guard options.count == 2 else { throw DeployError.invalidArgument("submit takes a worker name and a spec path.") }
        let (name, specPath) = (options[0], options[1])
        if let owner { try WorkerNames.validate(owner: owner) }

        let data = specPath == "-" ? standardInput() : try readFile(specPath)
        var job = AgentJob(spec: try AgentSpec.decode(from: data), webhookSecret: environment[AgentRuntimeCommand.webhookSecretVariable], owner: owner)
        if let runID { job.runID = runID }
        if let webhook {
            guard let url = URL(string: webhook), url.host != nil else { throw DeployError.invalidArgument("Invalid webhook URL: \(webhook)") }
            job.webhookURL = url
        }
        do { try job.validate() } catch { throw DeployError.invalidArgument(error.localizedDescription) }

        let worker = try await compute.worker(named: name)
        if let workerOwner = worker.owner, workerOwner != owner {
            throw DeployError.invalidArgument("Worker '\(name)' is isolated for owner '\(workerOwner)'; submit with --owner \(workerOwner).")
        }
        // The job, including any webhook secret, travels on stdin so it never appears in a process list.
        let output = try await connection(to: worker).run(
            "docker exec -i \(WorkerProvisioning.containerName) langtools-agent enqueue --job --spool /spool",
            stdin: try job.encoded()
        )
        standardOutput(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func status(_ options: inout [String]) async throws -> Int32 {
        guard options.count == 2 else { throw DeployError.invalidArgument("status takes a worker name and a run ID.") }
        guard AgentJob.isValidRunID(options[1]) else { throw DeployError.invalidArgument("Invalid run ID '\(options[1])'.") }
        let connection = try connection(to: try await compute.worker(named: options[0]))
        let output = try await connection.attempt("docker exec \(WorkerProvisioning.containerName) langtools-agent status --spool /spool \(shellQuote(options[1]))")
        if !output.stdout.isEmpty { standardOutput(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if !output.stderrString.isEmpty { standardError(output.stderrString) }
        return output.status == 0 ? 0 : 1
    }

    private func logs(_ options: inout [String]) async throws {
        let lines = try take("--lines", from: &options).map { value -> Int in
            guard let n = Int(value), n > 0 else { throw DeployError.invalidArgument("--lines must be a positive integer.") }
            return n
        } ?? 200
        let name = try single(&options, "logs takes one worker name.")
        let output = try await connection(to: try await compute.worker(named: name))
            .run("journalctl -u \(WorkerProvisioning.serviceName) --no-pager -n \(lines)")
        standardOutput(output.stdoutString.trimmingCharacters(in: .newlines))
    }

    private func list(_ options: inout [String]) async throws {
        guard options.isEmpty else { throw DeployError.invalidArgument("list takes no arguments.") }
        let workers = try await compute.workers()
        standardOutput(["NAME", "OWNER", "STATUS", "IP", "REGION", "SIZE"].joined(separator: "\t"))
        for worker in workers {
            standardOutput([worker.name, worker.owner ?? "(shared)", worker.status, worker.publicIPv4 ?? "-", worker.region ?? "-", worker.size ?? "-"].joined(separator: "\t"))
        }
    }

    private func destroy(_ options: inout [String]) async throws -> Int32 {
        let force = take(flag: "--force", from: &options)
        let name = try single(&options, "destroy takes one worker name.")
        let worker = try await compute.worker(named: name)
        guard force else {
            standardError("This deletes droplet \(worker.id) (\(worker.publicIPv4 ?? "no IP")) with its queue and results. Run again with --force to confirm.")
            return 2
        }
        try await compute.deleteWorker(worker)
        await forgetHostKey(of: worker)
        standardOutput("\(name)\tdestroyed")
        return 0
    }

    // MARK: - Setup steps

    private func connection(to worker: WorkerHost) throws -> WorkerConnection {
        guard let ip = worker.publicIPv4 else { throw DeployError.notReady("Worker '\(worker.name)' has no public IPv4 address yet.") }
        try FileManager.default.createDirectory(at: knownHostsFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return WorkerConnection(host: ip, knownHostsFile: knownHostsFile, identityFile: environment["LANGTOOLS_DEPLOY_SSH_IDENTITY"], runner: runner)
    }

    private func forgetHostKey(of worker: WorkerHost) async {
        guard let ip = worker.publicIPv4, FileManager.default.fileExists(atPath: knownHostsFile.path) else { return }
        _ = try? await runner.run("ssh-keygen", ["-R", ip, "-f", knownHostsFile.path], stdin: nil)
    }

    private func waitForBoot(_ connection: WorkerConnection) async throws {
        let deadline = Date().addingTimeInterval(bootTimeout)
        while try await connection.attempt("true").status != 0 {
            guard Date() < deadline else { throw DeployError.notReady("The droplet did not accept SSH within \(Int(bootTimeout))s.") }
            try await sleep(5)
        }
        // 0 is done, 2 is done with warnings; anything else means the setup script failed.
        let status = try await connection.attempt("cloud-init status --wait")
        guard status.status == 0 || status.status == 2 else {
            throw DeployError.notReady("First-boot setup failed: \(status.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) \(status.stderrString). See /var/log/cloud-init-output.log on the droplet.")
        }
    }

    private func install(config: WorkerProvisioning.WorkerConfig, env: Data?, on connection: WorkerConnection) async throws {
        standardError("Uploading configuration...")
        if let env { try await connection.upload(env, to: WorkerProvisioning.envFile) }
        if let credentials = try await compute.registryCredentials(for: config.image) {
            try await connection.upload(credentials, to: "\(WorkerProvisioning.dockerConfigDirectory)/config.json")
        }
        try await connection.upload(Data(config.fileContents.utf8), to: WorkerProvisioning.workerConfigFile)
        try await connection.run("systemctl restart \(WorkerProvisioning.serviceName)")

        standardError("Starting \(config.image)...")
        let deadline = Date().addingTimeInterval(startTimeout)
        while try await connection.attempt("docker exec \(WorkerProvisioning.containerName) langtools-agent tools").status != 0 {
            guard Date() < deadline else {
                let log = try? await connection.attempt("journalctl -u \(WorkerProvisioning.serviceName) --no-pager -n 30").stdoutString
                throw DeployError.notReady("The worker did not start within \(Int(startTimeout))s. Recent log:\n\(log ?? "(unavailable)")")
            }
            try await sleep(5)
        }
    }

    private func loadEnvFile(_ path: String) throws -> Data {
        let data: Data
        do { data = try readFile(path) } catch { throw DeployError.invalidArgument("Could not read \(path): \(error.localizedDescription)") }
        let keys = try WorkerProvisioning.validateEnvFile(String(decoding: data, as: UTF8.self))
        guard keys.contains(where: { $0.hasSuffix("_API_KEY") }) else {
            throw DeployError.invalidArgument("\(path) sets no *_API_KEY variable, so the worker could not call any provider.")
        }
        if !keys.contains(AgentRuntimeCommand.webhookSecretVariable) {
            standardError("warning: \(path) has no \(AgentRuntimeCommand.webhookSecretVariable); webhook deliveries will be unsigned unless each job brings a secret.")
        }
        return data
    }

    // MARK: - Arguments

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

    private func parseConcurrency(_ value: String) throws -> Int {
        guard let n = Int(value) else { throw DeployError.invalidArgument("--concurrency must be an integer.") }
        return n
    }

    static func defaultKnownHostsFile(environment: [String: String]) -> URL {
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".config", isDirectory: true)
        return config.appendingPathComponent("langtools-agent/known_hosts")
    }
}
