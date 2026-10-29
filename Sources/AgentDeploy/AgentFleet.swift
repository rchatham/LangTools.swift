//
//  AgentFleet.swift
//  AgentDeploy
//
//  Hosts and the workers on them. A host is any machine with Docker: this one, a server
//  reachable over SSH, or a machine a `ComputeProvider` creates. A worker is a
//  langtools-agent container on a host. The `langtools-agent-deploy` command is a thin
//  layer over this type; code can use it directly to hand work to a worker and wait for
//  the result.
//

import Foundation
import AgentRuntime

public struct AgentFleet {
    public var store: FleetStore
    public var runner: CommandRunner
    /// Providers that can create hosts, by `ComputeProvider.id`.
    public var providers: [String: ComputeProvider]
    /// Host keys of SSH hosts are pinned here on first connection.
    public var knownHostsFile: URL
    /// Progress messages, such as "Waiting for first-boot setup...".
    public var log: (String) -> Void
    var sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    /// Time allowed for a new machine to accept SSH and finish first-boot setup.
    var bootTimeout: TimeInterval = 600
    /// Time allowed for a new worker to start answering.
    var startTimeout: TimeInterval = 300

    public init(store: FleetStore, runner: CommandRunner, providers: [ComputeProvider] = [], knownHostsFile: URL? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.runner = runner
        self.providers = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.knownHostsFile = knownHostsFile ?? store.file.deletingLastPathComponent().appendingPathComponent("known_hosts")
        self.log = log
    }

    // MARK: - Hosts

    public func hosts() throws -> [HostRecord] { try store.load().allHosts }

    public func shell(for host: HostRecord) throws -> HostShell {
        switch host.kind {
        case .local:
            return LocalShell(runner: runner)
        case .ssh:
            guard let address = host.address else { throw DeployError.invalidArgument("Host '\(host.name)' has no SSH address.") }
            return SSHShell(address: address, port: host.port, identityFile: host.identityFile, knownHostsFile: knownHostsFile, runner: runner)
        }
    }

    /// The Docker server version on the host; throws when Docker isn't reachable there.
    @discardableResult
    public func checkHost(_ host: HostRecord) async throws -> String {
        let output = try await shell(for: host).attempt("docker version --format '{{.Server.Version}}'")
        guard output.status == 0 else {
            let reason = [output.stderrString, output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)].first { !$0.isEmpty } ?? "exit status \(output.status)"
            throw DeployError.notReady("Docker isn't usable on host '\(host.name)': \(reason)")
        }
        return output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Registers an existing machine. It must already have Docker, and the SSH user must be able to run it.
    public func addHost(_ host: HostRecord) async throws {
        try WorkerNames.validate(name: host.name)
        if let owner = host.owner { try WorkerNames.validate(owner: owner) }
        guard host.kind == .ssh, let address = host.address, !address.isEmpty, !address.hasPrefix("-") else {
            throw DeployError.invalidArgument("A host needs an SSH address such as user@203.0.113.7.")
        }
        var registry = try store.load()
        guard !registry.allHosts.contains(where: { $0.name == host.name }) else { throw DeployError.invalidArgument("A host named '\(host.name)' already exists.") }
        let version = try await checkHost(host)
        log("Docker \(version) is reachable on \(address).")
        registry.upsert(host)
        try store.save(registry)
    }

    /// Creates a machine with `provider`, installs Docker on it, and registers it.
    public func createHost(name: String, provider providerID: String, owner: String? = nil, region: String? = nil, size: String? = nil, sshKeys: [String] = []) async throws -> HostRecord {
        try WorkerNames.validate(name: name)
        if let owner { try WorkerNames.validate(owner: owner) }
        guard let provider = providers[providerID] else { throw DeployError.invalidArgument("Unknown provider '\(providerID)'. Available: \(providers.keys.sorted().joined(separator: ", ")).") }
        var registry = try store.load()
        guard !registry.allHosts.contains(where: { $0.name == name }) else { throw DeployError.invalidArgument("A host named '\(name)' already exists.") }

        log("Creating \(provider.displayName) machine for host '\(name)'...")
        let machine = try await provider.createMachine(MachineRequest(name: name, owner: owner, region: region, size: size, sshKeys: sshKeys))
        guard let ip = machine.publicIPv4 else { throw DeployError.notReady("Machine \(machine.id) has no public IPv4 address.") }
        let host = HostRecord(name: name, kind: .ssh, address: "\(provider.sshUser)@\(ip)", owner: owner, provider: provider.id, machineID: machine.id)
        // Recorded before setup, so a failed setup can still be cleaned up with `host destroy`.
        registry.upsert(host)
        try store.save(registry)

        await forgetHostKey(ip)  // A reused IP may have an old machine's key pinned.
        log("Machine \(machine.id) is at \(ip); waiting for first-boot setup...")
        let shell = try shell(for: host)
        let deadline = Date().addingTimeInterval(bootTimeout)
        while try await shell.attempt("true").status != 0 {
            guard Date() < deadline else { throw DeployError.notReady("The machine did not accept SSH within \(Int(bootTimeout))s. Remove it with `langtools-agent-deploy host destroy \(name) --force`.") }
            try await sleep(5)
        }
        // 0 is done, 2 is done with warnings; anything else means the setup script failed.
        let setup = try await shell.attempt("cloud-init status --wait")
        guard setup.status == 0 || setup.status == 2 else {
            throw DeployError.notReady("First-boot setup failed: \(setup.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) \(setup.stderrString). See /var/log/cloud-init-output.log on the machine, or remove it with `langtools-agent-deploy host destroy \(name) --force`.")
        }
        try await checkHost(host)
        return host
    }

    /// Forgets a host. The machine and any workers on it are left as they are.
    public func removeHost(_ name: String) throws {
        guard name != HostRecord.local.name else { throw DeployError.invalidArgument("The local host can't be removed.") }
        var registry = try store.load()
        _ = try registry.host(named: name)
        let workers = registry.workers.filter { $0.host == name }.map(\.name)
        guard workers.isEmpty else { throw DeployError.invalidArgument("Host '\(name)' still has workers: \(workers.joined(separator: ", ")). Destroy them first.") }
        registry.hosts.removeAll { $0.name == name }
        try store.save(registry)
    }

    /// Deletes a provider-created machine, with everything on it, and forgets it.
    public func destroyHost(_ name: String) async throws {
        var registry = try store.load()
        let host = try registry.host(named: name)
        guard let providerID = host.provider, let machineID = host.machineID else {
            throw DeployError.invalidArgument("Host '\(name)' wasn't created by a provider; use `host remove` to forget it.")
        }
        guard let provider = providers[providerID] else { throw DeployError.invalidArgument("Provider '\(providerID)' isn't available.") }
        try await provider.deleteMachine(id: machineID)
        if let ip = host.address?.split(separator: "@").last { await forgetHostKey(String(ip)) }
        registry.hosts.removeAll { $0.name == name }
        registry.workers.removeAll { $0.host == name }
        try store.save(registry)
    }

    private func forgetHostKey(_ ip: String) async {
        guard FileManager.default.fileExists(atPath: knownHostsFile.path) else { return }
        _ = try? await runner.run("ssh-keygen", ["-R", ip, "-f", knownHostsFile.path], stdin: nil)
    }

    // MARK: - Workers

    /// Starts a worker on `hostName`. `env` is the worker's env file: provider API keys
    /// and `LANGTOOLS_WEBHOOK_SECRET`. `registryConfig` is a Docker `config.json` for a
    /// private registry; for provider-created hosts the provider supplies one if needed.
    public func createWorker(_ configuration: WorkerContainer.Configuration, on hostName: String, env: Data, registryConfig: Data? = nil, pull: Bool = false) async throws {
        var configuration = configuration
        var registry = try store.load()
        let host = try registry.host(named: hostName)
        if let hostOwner = host.owner {
            guard configuration.owner == nil || configuration.owner == hostOwner else {
                throw DeployError.invalidArgument("Host '\(hostName)' is dedicated to owner '\(hostOwner)'.")
            }
            configuration.owner = hostOwner
        }
        try configuration.validate()
        guard !registry.workers.contains(where: { $0.name == configuration.name }) else { throw DeployError.workerExists(configuration.name) }

        let shell = try shell(for: host)
        try await checkHost(host)
        guard try await shell.attempt("docker container inspect \(shellQuote(WorkerContainer.containerName(configuration.name)))").status != 0 else {
            throw DeployError.invalidArgument("Host '\(hostName)' already has a container named \(WorkerContainer.containerName(configuration.name)). Run `langtools-agent-deploy list` to adopt it.")
        }
        try await shell.upload(env, to: WorkerContainer.envFile(configuration.name))
        try await start(configuration, on: host, shell: shell, registryConfig: registryConfig, pull: pull)
        registry.upsert(WorkerRecord(name: configuration.name, host: hostName, owner: configuration.owner))
        try store.save(registry)
    }

    /// Recreates a worker with a new image, concurrency or env file. Its queue and results are kept.
    public func configureWorker(_ name: String, image: String? = nil, concurrency: Int? = nil, env: Data? = nil, registryConfig: Data? = nil, pull: Bool = false) async throws {
        let (record, host, shell) = try locate(name)
        guard let current = try await inspect(on: shell).first(where: { $0.name == name }) else {
            throw DeployError.notReady("Worker '\(name)' has no container on host '\(host.name)'.")
        }
        let configuration = WorkerContainer.Configuration(name: name, image: image ?? current.image, owner: record.owner, concurrency: concurrency ?? current.concurrency ?? 2, network: current.network)
        try configuration.validate()
        if let env { try await shell.upload(env, to: WorkerContainer.envFile(name)) }
        log("Stopping \(name) (running jobs get up to five minutes)...")
        try await shell.run(WorkerContainer.removeContainerCommand(name))
        try await start(configuration, on: host, shell: shell, registryConfig: registryConfig, pull: pull)
    }

    private func start(_ configuration: WorkerContainer.Configuration, on host: HostRecord, shell: HostShell, registryConfig: Data?, pull: Bool) async throws {
        var credentials = registryConfig
        if credentials == nil, let providerID = host.provider, let provider = providers[providerID] {
            credentials = try await provider.registryCredentials(for: configuration.image)
        }
        if let credentials { try await shell.upload(credentials, to: WorkerContainer.registryConfig(configuration.name)) }
        log("Starting \(configuration.image) as \(configuration.name) on \(host.name)...")
        try await shell.run(WorkerContainer.pullCommand(configuration, usesRegistryConfig: credentials != nil, pull: pull))
        try await shell.run(WorkerContainer.runCommand(configuration))

        let deadline = Date().addingTimeInterval(startTimeout)
        while try await shell.attempt(WorkerContainer.exec(configuration.name, "tools")).status != 0 {
            guard Date() < deadline else {
                let logs = try? await shell.attempt("docker logs --tail 30 \(shellQuote(WorkerContainer.containerName(configuration.name))) 2>&1").stdoutString
                throw DeployError.notReady("Worker '\(configuration.name)' did not start within \(Int(startTimeout))s. Recent log:\n\(logs ?? "(unavailable)")")
            }
            try await sleep(2)
        }
    }

    /// Stops and removes a worker. Its queue and results are deleted too unless `keepResults`.
    public func destroyWorker(_ name: String, keepResults: Bool = false) async throws {
        let (_, _, shell) = try locate(name)
        try await shell.run(WorkerContainer.removeContainerCommand(name))
        if !keepResults {
            try await shell.run("docker volume rm -f \(shellQuote(WorkerContainer.volumeName(name))) >/dev/null")
            try await shell.run("rm -rf -- \(WorkerContainer.configDirectory(name))")
        }
        var registry = try store.load()
        registry.workers.removeAll { $0.name == name }
        try store.save(registry)
    }

    /// Queues a job on a worker and returns its run ID. A worker with an owner only takes that owner's jobs.
    @discardableResult
    public func submit(_ job: AgentJob, to name: String) async throws -> String {
        do { try job.validate() } catch { throw DeployError.invalidArgument(error.localizedDescription) }
        let (record, _, shell) = try locate(name)
        if let owner = record.owner, owner != job.owner {
            throw DeployError.invalidArgument("Worker '\(name)' is isolated for owner '\(owner)'; submit with --owner \(owner).")
        }
        // The job, including any webhook secret, travels on stdin so it never appears in a process list.
        try await shell.run(WorkerContainer.exec(name, "enqueue --job --spool /spool", interactive: true), stdin: job.encoded())
        return job.runID
    }

    public struct JobStatus: Equatable {
        public var runID: String
        public var state: AgentSpool.State
        public var result: AgentRunResult?
    }

    public func status(of runID: String, on name: String) async throws -> JobStatus {
        guard AgentJob.isValidRunID(runID) else { throw DeployError.invalidArgument("Invalid run ID '\(runID)'.") }
        let (_, _, shell) = try locate(name)
        let output = try await shell.attempt(WorkerContainer.exec(name, "status --spool /spool \(shellQuote(runID))"))
        guard let object = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
              let state = (object["state"] as? String).flatMap(AgentSpool.State.init(rawValue:))
        else { throw DeployError.unexpectedOutput("Worker '\(name)' did not report a status: \(output.stderrString)") }
        let result = try (object["result"]).map { try AgentRunResult.decode(from: JSONSerialization.data(withJSONObject: $0)) }
        return JobStatus(runID: runID, state: state, result: result)
    }

    /// Polls until the job is done and returns its result.
    public func waitForResult(of runID: String, on name: String, pollInterval: TimeInterval = 2, timeout: TimeInterval? = nil) async throws -> AgentRunResult {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            let status = try await status(of: runID, on: name)
            if let result = status.result { return result }
            guard status.state != .unknown else { throw DeployError.unexpectedOutput("Worker '\(name)' has no job '\(runID)'.") }
            if let deadline, Date() >= deadline { throw DeployError.notReady("Job '\(runID)' was still \(status.state.rawValue) after \(Int(timeout ?? 0))s.") }
            try await sleep(pollInterval)
        }
    }

    public func logs(of name: String, lines: Int = 200) async throws -> String {
        let (_, _, shell) = try locate(name)
        return try await shell.run("docker logs --tail \(max(1, lines)) \(shellQuote(WorkerContainer.containerName(name))) 2>&1").stdoutString
    }

    public struct WorkerListing: Equatable {
        public var name: String
        public var host: String
        public var owner: String?
        /// Docker's state, such as `running`; `missing` when the host is reachable but the
        /// container is gone, `unreachable` when the host can't be reached.
        public var state: String
        public var image: String?
        public var concurrency: Int?
    }

    /// Lists workers on every host. Worker containers found on a host but missing from the
    /// registry are added to it, so a lost registry can be rebuilt by adding the hosts again.
    public func listWorkers() async throws -> [WorkerListing] {
        var registry = try store.load()
        var listings: [WorkerListing] = []
        var changed = false
        for host in registry.allHosts {
            let found: [WorkerContainer.Found]
            do { found = try await inspect(on: shell(for: host)) }
            catch {
                // The local host only matters if Docker is installed and there are workers on it.
                if host.kind == .local && !registry.workers.contains(where: { $0.host == host.name }) { continue }
                listings += registry.workers.filter { $0.host == host.name }.map { WorkerListing(name: $0.name, host: host.name, owner: $0.owner, state: "unreachable") }
                continue
            }
            for worker in registry.workers where worker.host == host.name && !found.contains(where: { $0.name == worker.name }) {
                listings.append(WorkerListing(name: worker.name, host: host.name, owner: worker.owner, state: "missing"))
            }
            for container in found {
                if !registry.workers.contains(where: { $0.name == container.name }) {
                    registry.upsert(WorkerRecord(name: container.name, host: host.name, owner: container.owner))
                    changed = true
                }
                listings.append(WorkerListing(name: container.name, host: host.name, owner: container.owner, state: container.state, image: container.image, concurrency: container.concurrency))
            }
        }
        if changed { try store.save(registry) }
        return listings.sorted { ($0.host, $0.name) < ($1.host, $1.name) }
    }

    private func inspect(on shell: HostShell) async throws -> [WorkerContainer.Found] {
        try WorkerContainer.parseInspect(try await shell.run(WorkerContainer.inspectAllCommand).stdout)
    }

    private func locate(_ name: String) throws -> (WorkerRecord, HostRecord, HostShell) {
        let registry = try store.load()
        let record = try registry.worker(named: name)
        let host = try registry.host(named: record.host)
        return (record, host, try shell(for: host))
    }
}
