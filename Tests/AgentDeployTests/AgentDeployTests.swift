//
//  AgentDeployTests.swift
//  AgentDeployTests
//

import XCTest
@testable import AgentDeploy
import AgentRuntime

/// Records commands and answers them from handlers matched on the command line.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
        var stdin: Data?
        /// The shell command for local and ssh calls, the whole command line otherwise.
        var command: String { ["ssh", "/bin/sh"].contains(executable) ? (arguments.last ?? "") : ([executable] + arguments).joined(separator: " ") }
        var isLocal: Bool { executable == "/bin/sh" }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var handlers: [(match: (Call) -> Bool, respond: (Call) -> CommandOutput)] = []

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    func calls(_ executable: String) -> [Call] { calls.filter { $0.executable == executable } }
    var shellCommands: [String] { calls.filter { ["ssh", "/bin/sh"].contains($0.executable) }.map(\.command) }

    /// Later handlers take precedence.
    func on(_ match: @escaping (Call) -> Bool, respond: @escaping (Call) -> CommandOutput) {
        lock.lock(); handlers.insert((match, respond), at: 0); lock.unlock()
    }

    func on(_ fragment: String, status: Int32 = 0, stdout: String = "", stderr: String = "") {
        on({ $0.command.contains(fragment) }) { _ in CommandOutput(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)) }
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandOutput {
        let call = Call(executable: executable, arguments: arguments, stdin: stdin)
        return record(call)?.respond(call) ?? CommandOutput(status: 0)
    }

    private func record(_ call: Call) -> (match: (Call) -> Bool, respond: (Call) -> CommandOutput)? {
        lock.lock(); defer { lock.unlock() }
        _calls.append(call)
        return handlers.first { $0.match(call) }
    }
}

final class AgentDeployTests: XCTestCase {
    private var runner: FakeRunner!
    private var temp: URL!
    private var store: FleetStore!
    private var files: [String: Data] = [:]
    private var output: [String] = []
    private var errors: [String] = []
    private var stdin = Data()

    private let specJSON = #"{"name": "Helper", "instructions": "Answer.", "provider": "openai", "model": "gpt-4o", "messages": [{"role": "user", "content": "Ping"}]}"#

    override func setUp() {
        super.setUp()
        runner = FakeRunner()
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("deploy-\(UUID().uuidString)", isDirectory: true)
        store = FleetStore(file: temp.appendingPathComponent("fleet.json"))
        files = [
            "worker.env": Data("OPENAI_API_KEY=sk-test\nLANGTOOLS_WEBHOOK_SECRET=whsec\n".utf8),
            "spec.json": Data(specJSON.utf8),
        ]
        output = []
        errors = []
        stdin = Data()
        // A healthy Docker host with no workers yet.
        runner.on("docker version", stdout: "29.1.3\n")
        runner.on({ $0.command.hasPrefix("docker container inspect") }) { _ in CommandOutput(status: 1) }
        runner.on(WorkerContainer.inspectAllCommand, stdout: "[]")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    private var digitalOcean: DigitalOceanCompute {
        var compute = DigitalOceanCompute(runner: runner)
        compute.writeTemporaryFile = { contents in
            let url = self.temp.appendingPathComponent("user-data.sh")
            try FileManager.default.createDirectory(at: self.temp, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            return url
        }
        compute.removeFile = { _ in }  // Kept so the test can read it.
        return compute
    }

    private func fleet() -> AgentFleet {
        var fleet = AgentFleet(store: store, runner: runner, providers: [digitalOcean])
        fleet.sleep = { _ in }
        return fleet
    }

    private func command(environment: [String: String] = [:]) -> AgentDeployCommand {
        AgentDeployCommand(
            fleet: fleet(), environment: environment,
            readFile: { path in
                guard let data = self.files[path] else { throw CocoaError(.fileNoSuchFile) }
                return data
            },
            standardInput: { self.stdin },
            standardOutput: { self.output.append($0) },
            standardError: { self.errors.append($0) }
        )
    }

    private func givenRegistry(hosts: [HostRecord] = [], workers: [WorkerRecord] = []) throws {
        try store.save(FleetRegistry(hosts: hosts, workers: workers))
    }

    private let server = HostRecord(name: "box", kind: .ssh, address: "reid@10.0.0.5", port: 2222)

    /// `docker inspect` output for worker containers, as Docker prints it (trimmed).
    private func inspectJSON(_ containers: [(name: String, owner: String?, state: String)]) -> String {
        "[" + containers.map { c in
            var labels = #""dev.langtools.agent.worker":"\#(c.name)","dev.langtools.agent.concurrency":"2""#
            if let owner = c.owner { labels += #","dev.langtools.agent.owner":"\#(owner)""# }
            return #"{"Id":"abc","Name":"/langtools-agent-\#(c.name)","State":{"Status":"\#(c.state)","Running":true},"Config":{"Image":"langtools-agent:dev","Labels":{\#(labels)}}}"#
        }.joined(separator: ",") + "]"
    }

    // MARK: - Local workers

    func testCreateLocalWorker() async throws {
        let status = await command().run(["create", "helper", "--image", "langtools-agent:dev", "--env-file", "worker.env", "--concurrency", "3"])

        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        XCTAssertTrue(runner.calls.allSatisfy { $0.executable != "ssh" }, "Local workers need no SSH")
        let commands = runner.shellCommands
        XCTAssertEqual(commands.first, "docker version --format '{{.Server.Version}}'")
        let upload = try XCTUnwrap(runner.calls.first { $0.command.contains("/env.new") })
        XCTAssertEqual(upload.command, #"umask 077 && mkdir -p "$HOME/.config/langtools-agent/workers/helper" && cat > "$HOME/.config/langtools-agent/workers/helper/env.new" && mv -f "$HOME/.config/langtools-agent/workers/helper/env.new" "$HOME/.config/langtools-agent/workers/helper/env""#)
        XCTAssertEqual(upload.stdin, files["worker.env"])
        XCTAssertTrue(commands.contains("docker image inspect 'langtools-agent:dev' >/dev/null 2>&1 || docker pull 'langtools-agent:dev'"), "A local image is used without a registry")
        XCTAssertTrue(commands.contains(
            "docker run -d --name 'langtools-agent-helper' --restart unless-stopped --stop-timeout 300 --label 'dev.langtools.agent.worker=helper' --label 'dev.langtools.agent.concurrency=3' --env-file \"$HOME/.config/langtools-agent/workers/helper/env\" -v 'langtools-agent-helper':/spool --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 'langtools-agent:dev' worker --spool /spool --concurrency 3"
        ), commands.joined(separator: "\n"))
        XCTAssertEqual(commands.last, "docker exec 'langtools-agent-helper' langtools-agent tools")
        XCTAssertFalse(runner.calls.contains { $0.arguments.joined(separator: " ").contains("sk-test") }, "Secrets never appear in arguments")
        XCTAssertEqual(try store.load().workers, [WorkerRecord(name: "helper", host: "local")])
    }

    func testCreateWithoutEnvFileWarnsAndUsesEmptyFile() async throws {
        let status = await command().run(["create", "ollama", "--image", "langtools-agent:dev", "--network", "host"])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        XCTAssertTrue(errors.contains { $0.contains("no API keys") })
        XCTAssertEqual(runner.calls.first { $0.command.contains("/env.new") }?.stdin, Data())
        XCTAssertTrue(runner.shellCommands.contains { $0.contains("--network 'host'") && $0.contains("dev.langtools.agent.network=host") })
    }

    func testCreateRejectsBadInputBeforeTouchingDocker() async throws {
        try givenRegistry(workers: [WorkerRecord(name: "taken", host: "local")])
        files["quoted.env"] = Data("OPENAI_API_KEY=\"sk-test\"\n".utf8)
        let cases: [[String]] = [
            ["create", "Bad_Name", "--image", "img"],
            ["create", "w1", "--image", "img; rm -rf /"],
            ["create", "w1", "--image", "--privileged"],
            ["create", "w1", "--image", "img", "--network", "host; reboot"],
            ["create", "w1", "--image", "img", "--env-file", "missing.env"],
            ["create", "w1", "--image", "img", "--env-file", "quoted.env"],
            ["create", "w1", "--image", "img", "--owner", "bad owner"],
            ["create", "w1"],
            ["create", "w1", "--image", "img", "--host", "nowhere"],
            ["create", "taken", "--image", "img"],
        ]
        for arguments in cases {
            let status = await command().run(arguments)
            XCTAssertNotEqual(status, 0, "\(arguments)")
        }
        XCTAssertFalse(runner.shellCommands.contains { $0.hasPrefix("docker run") }, "No container may be started")
        XCTAssertTrue(errors.contains { $0.contains("remove the quotes") }, "\(errors)")
    }

    func testCreateFailsClearlyWithoutDocker() async {
        runner.on("docker version", status: 1, stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.")
        let status = await command().run(["create", "w1", "--image", "img"])
        XCTAssertEqual(status, 1)
        XCTAssertTrue(errors.contains { $0.contains("Docker isn't usable on host 'local': Cannot connect") }, "\(errors)")
    }

    func testCreateReportsWorkerThatNeverStarts() async {
        var fleet = fleet()
        fleet.startTimeout = 0
        runner.on("langtools-agent tools", status: 1)
        runner.on("docker logs", stdout: "error: --concurrency must be a positive integer.\n")
        let command = AgentDeployCommand(fleet: fleet, environment: [:], readFile: { _ in Data() }, standardOutput: { self.output.append($0) }, standardError: { self.errors.append($0) })
        let status = await command.run(["create", "w1", "--image", "img"])
        XCTAssertEqual(status, 1)
        XCTAssertTrue(errors.contains { $0.contains("did not start") && $0.contains("--concurrency must be") }, "\(errors)")
    }

    // MARK: - SSH hosts

    func testAddSSHHostChecksDockerThere() async throws {
        let status = await command().run(["host", "add", "box", "--ssh", "reid@10.0.0.5", "--port", "2222", "--identity", "~/.ssh/box"])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        let call = try XCTUnwrap(runner.calls("ssh").first)
        XCTAssertEqual(call.command, "docker version --format '{{.Server.Version}}'")
        XCTAssertTrue(call.arguments.contains("reid@10.0.0.5"))
        XCTAssertEqual(call.arguments.firstIndex(of: "-p").map { call.arguments[$0 + 1] }, "2222")
        XCTAssertEqual(call.arguments.firstIndex(of: "-i").map { call.arguments[$0 + 1] }, "~/.ssh/box")
        XCTAssertTrue(call.arguments.contains("StrictHostKeyChecking=accept-new") && call.arguments.contains("BatchMode=yes"))
        XCTAssertEqual(try store.load().hosts, [HostRecord(name: "box", kind: .ssh, address: "reid@10.0.0.5", port: 2222, identityFile: "~/.ssh/box")])

        let duplicate = await command().run(["host", "add", "box", "--ssh", "x@y"])
        XCTAssertEqual(duplicate, 2)
        let local = await command().run(["host", "add", "local", "--ssh", "x@y"])
        XCTAssertEqual(local, 2)
    }

    func testWorkerOnSSHHostRunsThere() async throws {
        try givenRegistry(hosts: [server])
        let status = await command().run(["create", "remote", "--host", "box", "--image", "ghcr.io/acme/langtools-agent:1", "--env-file", "worker.env"])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        XCTAssertTrue(runner.calls.filter { $0.isLocal }.isEmpty, "Nothing runs locally")
        XCTAssertTrue(runner.calls("ssh").contains { $0.command.hasPrefix("docker run -d --name 'langtools-agent-remote'") })
        XCTAssertFalse(runner.calls("doctl").contains { $0.arguments.first == "registry" }, "Hosts without a provider get no provider credentials")
    }

    func testPrivateRegistryConfigIsUploadedAndUsed() async throws {
        files["docker.json"] = Data(#"{"auths":{"ghcr.io":{"auth":"abc"}}}"#.utf8)
        let status = await command().run(["create", "w1", "--image", "ghcr.io/acme/private:1", "--registry-config", "docker.json", "--pull"])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        XCTAssertEqual(runner.calls.first { $0.command.contains("docker/config.json.new") }?.stdin, files["docker.json"])
        XCTAssertTrue(runner.shellCommands.contains(#"docker --config "$HOME/.config/langtools-agent/workers/w1/docker" pull 'ghcr.io/acme/private:1'"#), "--pull always pulls")
    }

    // MARK: - Provider hosts

    func testCreateDigitalOceanHostThenWorkerOnIt() async throws {
        runner.on("compute ssh-key list", stdout: #"[{"id":111,"name":"laptop","fingerprint":"aa:bb"}]"#)
        runner.on("compute droplet create", stdout: "[" + dropletJSON(id: 4242, host: "do1", owner: "alice") + "]")
        runner.on("cloud-init status --wait", stdout: "status: done")
        var sshAttempts = 0
        runner.on({ $0.command == "true" }) { _ in
            sshAttempts += 1
            return CommandOutput(status: sshAttempts < 3 ? 255 : 0, stderr: Data("Connection refused".utf8))
        }

        let created = await command().run(["host", "create", "do1", "--provider", "digitalocean", "--owner", "alice", "--region", "sfo3"])
        XCTAssertEqual(created, 0, errors.joined(separator: "\n"))
        let create = try XCTUnwrap(runner.calls("doctl").first { $0.arguments.starts(with: ["compute", "droplet", "create"]) })
        XCTAssertEqual(create.arguments, [
            "compute", "droplet", "create", "langtools-agent-do1",
            "--region", "sfo3", "--size", "s-1vcpu-1gb", "--image", "ubuntu-24-04-x64",
            "--ssh-keys", "111",
            "--tag-names", "langtools-agent,langtools-agent-host:do1,langtools-agent-owner:alice",
            "--user-data-file", temp.appendingPathComponent("user-data.sh").path,
            "--enable-monitoring", "--wait", "--output", "json",
        ])
        XCTAssertEqual(try String(contentsOf: temp.appendingPathComponent("user-data.sh")), HostBootstrap.script)
        XCTAssertEqual(sshAttempts, 3, "Retries SSH until the machine accepts it")
        XCTAssertEqual(try store.load().hosts, [HostRecord(name: "do1", kind: .ssh, address: "root@203.0.113.7", owner: "alice", provider: "digitalocean", machineID: "4242")])

        // The host is dedicated to alice: workers on it inherit the owner, others are refused.
        let bob = await command().run(["create", "w-bob", "--host", "do1", "--owner", "bob", "--image", "img"])
        XCTAssertEqual(bob, 2)
        runner.on("registry docker-config", stdout: #"{"auths":{"registry.digitalocean.com":{"auth":"t"}}}"#)
        let alice = await command().run(["create", "w-alice", "--host", "do1", "--image", "registry.digitalocean.com/acme/langtools-agent:1", "--env-file", "worker.env"])
        XCTAssertEqual(alice, 0, errors.joined(separator: "\n"))
        XCTAssertEqual(try store.load().worker(named: "w-alice").owner, "alice")
        XCTAssertTrue(runner.calls("ssh").contains { $0.command.contains("workers/w-alice/docker/config.json.new") }, "DOCR credentials come from the provider")
        XCTAssertTrue(runner.calls("ssh").contains { $0.command.contains(#"docker --config "$HOME/.config/langtools-agent/workers/w-alice/docker" pull"#) })
    }

    func testFailedFirstBootLeavesHostRecordedForCleanup() async throws {
        runner.on("compute ssh-key list", stdout: #"[{"id":1}]"#)
        runner.on("compute droplet create", stdout: "[" + dropletJSON(id: 7, host: "do1") + "]")
        runner.on("cloud-init status --wait", status: 1, stdout: "status: error")
        let status = await command().run(["host", "create", "do1", "--provider", "digitalocean"])
        XCTAssertEqual(status, 1)
        XCTAssertTrue(errors.contains { $0.contains("First-boot setup failed") && $0.contains("host destroy do1 --force") }, "\(errors)")
        XCTAssertEqual(try store.load().hosts.map(\.machineID), ["7"])

        let destroyed = await command().run(["host", "destroy", "do1", "--force"])
        XCTAssertEqual(destroyed, 0, errors.joined(separator: "\n"))
        XCTAssertTrue(runner.calls("doctl").contains { $0.arguments == ["compute", "droplet", "delete", "7", "--force"] })
        XCTAssertEqual(try store.load().hosts, [])
    }

    func testHostDestroyAndRemoveRules() async throws {
        try givenRegistry(hosts: [server], workers: [WorkerRecord(name: "w1", host: "box")])
        let unconfirmed = await command().run(["host", "destroy", "box"])
        XCTAssertEqual(unconfirmed, 2)
        let notProvider = await command().run(["host", "destroy", "box", "--force"])
        XCTAssertEqual(notProvider, 2, "Only provider-created machines can be destroyed")
        let busy = await command().run(["host", "remove", "box"])
        XCTAssertEqual(busy, 2, "A host with workers can't be forgotten")
        let local = await command().run(["host", "remove", "local"])
        XCTAssertEqual(local, 2)
        XCTAssertFalse(runner.calls("doctl").contains { $0.arguments.contains("delete") })
    }

    // MARK: - Jobs

    func testSubmitSendsJobOnStandardInput() async throws {
        try givenRegistry(hosts: [server], workers: [WorkerRecord(name: "shared", host: "box")])
        let status = await command(environment: ["LANGTOOLS_WEBHOOK_SECRET": "job-secret"])
            .run(["submit", "shared", "spec.json", "--webhook", "https://example.com/h", "--run-id", "r-1", "--owner", "bob"])

        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        let call = try XCTUnwrap(runner.calls("ssh").last)
        XCTAssertEqual(call.command, "docker exec -i 'langtools-agent-shared' langtools-agent enqueue --job --spool /spool")
        let job = try AgentJob.decode(from: XCTUnwrap(call.stdin))
        XCTAssertEqual([job.runID, job.owner, job.webhookSecret, job.webhookURL?.absoluteString, job.spec.name], ["r-1", "bob", "job-secret", "https://example.com/h", "Helper"])
        XCTAssertFalse(call.arguments.joined().contains("job-secret"))
        XCTAssertTrue(output.joined().contains(#""runID" : "r-1""#))
    }

    func testIsolatedWorkerOnlyTakesItsOwnersJobs() async throws {
        try givenRegistry(workers: [WorkerRecord(name: "alice", host: "local", owner: "alice")])
        let noOwner = await command().run(["submit", "alice", "spec.json"])
        XCTAssertEqual(noOwner, 2)
        let other = await command().run(["submit", "alice", "spec.json", "--owner", "bob"])
        XCTAssertEqual(other, 2)
        XCTAssertTrue(errors.contains { $0.contains("isolated for owner 'alice'") }, "\(errors)")
        XCTAssertFalse(runner.shellCommands.contains { $0.contains("enqueue") })
        let owner = await command().run(["submit", "alice", "spec.json", "--owner", "alice"])
        XCTAssertEqual(owner, 0)
    }

    func testSubmitAndWaitPollsUntilDone() async throws {
        try givenRegistry(workers: [WorkerRecord(name: "w1", host: "local")])
        var polls = 0
        runner.on({ $0.command.contains("langtools-agent status") }) { _ in
            polls += 1
            let body = polls < 3
                ? #"{"runID":"r-2","state":"running"}"#
                : #"{"runID":"r-2","state":"done","result":{"runID":"r-2","agent":"Helper","provider":"openai","model":"gpt-4o","status":"completed","output":"Pong","events":[],"startedAt":"2026-10-28T00:00:00Z","finishedAt":"2026-10-28T00:00:01Z"}}"#
            return CommandOutput(status: 0, stdout: Data(body.utf8))
        }
        let status = await command().run(["submit", "w1", "spec.json", "--run-id", "r-2", "--wait"])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        XCTAssertEqual(polls, 3)
        XCTAssertEqual(try AgentRunResult.decode(from: Data(output.joined().utf8)).output, "Pong")
    }

    func testWaitTimesOutAndUnknownJobFails() async throws {
        try givenRegistry(workers: [WorkerRecord(name: "w1", host: "local")])
        runner.on("langtools-agent status", stdout: #"{"runID":"r","state":"queued"}"#)
        do {
            _ = try await fleet().waitForResult(of: "r", on: "w1", timeout: 0)
            XCTFail("Should time out")
        } catch let error as DeployError {
            XCTAssertTrue(error.localizedDescription.contains("still queued"))
        }
        runner.on("langtools-agent status", status: 1, stdout: #"{"runID":"r","state":"unknown"}"#)
        let unknown = await command().run(["status", "w1", "r"])
        XCTAssertEqual(unknown, 1)
        let injection = await command().run(["status", "w1", "x;reboot"])
        XCTAssertEqual(injection, 2)
    }

    func testSubmitRejectsBadJobsLocally() async throws {
        try givenRegistry(workers: [WorkerRecord(name: "w1", host: "local")])
        files["bad.json"] = Data(#"{"name": "x"}"#.utf8)
        let badSpec = await command().run(["submit", "w1", "bad.json"])
        XCTAssertEqual(badSpec, 1)
        let insecure = await command().run(["submit", "w1", "spec.json", "--webhook", "http://example.com/h"])
        XCTAssertEqual(insecure, 2)
        let badID = await command().run(["submit", "w1", "spec.json", "--run-id", "../x"])
        XCTAssertEqual(badID, 2)
        let missing = await command().run(["submit", "nope", "spec.json"])
        XCTAssertEqual(missing, 1)
        XCTAssertFalse(runner.shellCommands.contains { $0.contains("enqueue") })
    }

    // MARK: - list, configure, destroy

    func testListMergesHostsAndAdoptsUnregisteredWorkers() async throws {
        try givenRegistry(hosts: [server, HostRecord(name: "gone", kind: .ssh, address: "x@192.0.2.1")],
                          workers: [WorkerRecord(name: "lost", host: "local"), WorkerRecord(name: "far", host: "gone")])
        runner.on({ $0.isLocal && $0.command == WorkerContainer.inspectAllCommand }) { _ in CommandOutput(status: 0, stdout: Data(self.inspectJSON([("a", nil, "running")]).utf8)) }
        runner.on({ $0.executable == "ssh" && $0.arguments.contains("reid@10.0.0.5") }) { _ in CommandOutput(status: 0, stdout: Data(self.inspectJSON([("b", "alice", "exited")]).utf8)) }
        runner.on({ $0.executable == "ssh" && $0.arguments.contains("x@192.0.2.1") }) { _ in CommandOutput(status: 255, stderr: Data("timed out".utf8)) }

        let status = await command().run(["list"])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        XCTAssertEqual(output, [
            "NAME\tHOST\tOWNER\tSTATE\tIMAGE\tCONCURRENCY",
            "b\tbox\talice\texited\tlangtools-agent:dev\t2",
            "far\tgone\t-\tunreachable\t-\t-",
            "a\tlocal\t-\trunning\tlangtools-agent:dev\t2",
            "lost\tlocal\t-\tmissing\t-\t-",
        ])
        let workers = try store.load().workers
        XCTAssertEqual(workers.first { $0.name == "b" }, WorkerRecord(name: "b", host: "box", owner: "alice"), "Found workers are adopted")
        XCTAssertNotNil(workers.first { $0.name == "a" })
    }

    func testListSkipsLocalHostWithoutDocker() async throws {
        runner.on(WorkerContainer.inspectAllCommand, status: 127, stderr: "docker: not found")
        let status = await command().run(["list"])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        XCTAssertEqual(output, ["NAME\tHOST\tOWNER\tSTATE\tIMAGE\tCONCURRENCY"])
    }

    func testConfigureRecreatesWithCurrentSettings() async throws {
        try givenRegistry(workers: [WorkerRecord(name: "w1", host: "local", owner: "alice")])
        runner.on(WorkerContainer.inspectAllCommand, stdout: inspectJSON([("w1", "alice", "running")]))
        let status = await command().run(["configure", "w1", "--image", "langtools-agent:2"])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        let commands = runner.shellCommands
        let removed = try XCTUnwrap(commands.firstIndex(of: WorkerContainer.removeContainerCommand("w1")))
        let started = try XCTUnwrap(commands.firstIndex { $0.hasPrefix("docker run") })
        XCTAssertLessThan(removed, started)
        XCTAssertTrue(commands[started].contains("'langtools-agent:2' worker --spool /spool --concurrency 2"), "Keeps concurrency")
        XCTAssertTrue(commands[started].contains("dev.langtools.agent.owner=alice"), "Keeps owner")
        XCTAssertFalse(commands.contains { $0.contains("/env.new") }, "Keys are kept unless replaced")
    }

    func testDestroyWorker() async throws {
        try givenRegistry(workers: [WorkerRecord(name: "w1", host: "local"), WorkerRecord(name: "w2", host: "local")])
        let unconfirmed = await command().run(["destroy", "w1"])
        XCTAssertEqual(unconfirmed, 2)
        XCTAssertTrue(runner.calls.isEmpty)

        let status = await command().run(["destroy", "w1", "--force"])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        XCTAssertEqual(runner.shellCommands, [
            WorkerContainer.removeContainerCommand("w1"),
            "docker volume rm -f 'langtools-agent-w1' >/dev/null",
            #"rm -rf -- "$HOME/.config/langtools-agent/workers/w1/""#,
        ])
        XCTAssertEqual(try store.load().workers.map(\.name), ["w2"])

        let kept = await command().run(["destroy", "w2", "--force", "--keep-results"])
        XCTAssertEqual(kept, 0)
        XCTAssertFalse(runner.shellCommands.contains { $0.contains("langtools-agent-w2") && $0.contains("volume rm") })
    }

    // MARK: - doctl

    /// A droplet as doctl prints it: godo's Droplet with empty fields omitted.
    private func dropletJSON(id: Int, host: String, owner: String? = nil, ip: String = "203.0.113.7") -> String {
        var tags = ["\"langtools-agent\"", "\"langtools-agent-host:\(host)\""]
        if let owner { tags.append("\"langtools-agent-owner:\(owner)\"") }
        return #"{"id":\#(id),"name":"langtools-agent-\#(host)","memory":1024,"vcpus":1,"disk":25,"region":{"slug":"nyc3","name":"New York 3","sizes":["s-1vcpu-1gb"],"available":true,"features":["metadata"]},"size_slug":"s-1vcpu-1gb","locked":false,"status":"active","networks":{"v4":[{"ip_address":"10.10.0.5","netmask":"255.255.0.0","gateway":"10.10.0.1","type":"private"},{"ip_address":"\#(ip)","netmask":"255.255.240.0","gateway":"203.0.113.1","type":"public"}],"v6":[{"ip_address":"2604:a880::1","netmask":64,"gateway":"2604:a880::","type":"public"}]},"created_at":"2026-10-28T03:00:00Z","tags":[\#(tags.joined(separator: ","))],"volume_ids":[]}"#
    }

    func testDigitalOceanMachinesParseAndIgnoreUntagged() async throws {
        runner.on("compute droplet list", stdout: "[" + dropletJSON(id: 1, host: "a", owner: "x") + #",{"id":2,"name":"other","status":"active","tags":["langtools-agent"]}]"#)
        let machines = try await DigitalOceanCompute(runner: runner).machines()
        XCTAssertEqual(machines, [Machine(id: "1", name: "a", owner: "x", status: "active", publicIPv4: "203.0.113.7", region: "nyc3", size: "s-1vcpu-1gb")])
        runner.on("compute droplet list", stdout: "\n")
        let empty = try await DigitalOceanCompute(runner: runner).machines()
        XCTAssertEqual(empty, [])
    }

    func testDoctlJSONErrorIsReportedOnce() async {
        runner.on("compute droplet create", status: 1, stdout: #"{"errors":[{"detail":"Unable to initialize DigitalOcean API client: access token is required. (hint: run 'doctl auth init')"}]}"#)
        let status = await command().run(["host", "create", "do1", "--provider", "digitalocean", "--ssh-key", "1"])
        XCTAssertEqual(status, 1)
        XCTAssertEqual(errors, ["error: doctl exited with status 1: Unable to initialize DigitalOcean API client: access token is required. (hint: run 'doctl auth init')"])
        XCTAssertEqual(runner.calls("doctl").count, 1, "A failed command is never re-run")
        XCTAssertEqual(try store.load().hosts, [], "Nothing is recorded for a machine that wasn't created")
    }

    func testUnknownProvider() async {
        let status = await command().run(["host", "create", "x", "--provider", "aws"])
        XCTAssertEqual(status, 2)
        XCTAssertTrue(errors.contains { $0.contains("Available: digitalocean") }, "\(errors)")
    }

    // MARK: - Pieces

    func testInspectParsing() throws {
        let found = try WorkerContainer.parseInspect(Data(inspectJSON([("w1", "alice", "running")]).utf8))
        XCTAssertEqual(found, [WorkerContainer.Found(name: "w1", owner: "alice", image: "langtools-agent:dev", state: "running", concurrency: 2, network: nil)])
        XCTAssertEqual(try WorkerContainer.parseInspect(Data(#"[{"Config":{"Labels":{"other":"x"}}}]"#.utf8)), [], "Unlabelled containers are ignored")
    }

    func testEnvFileValidation() throws {
        XCTAssertEqual(try WorkerContainer.validateEnvFile("# keys\nOPENAI_API_KEY=sk-1\n\nX_2=a=b\n"), ["OPENAI_API_KEY", "X_2"])
        XCTAssertThrowsError(try WorkerContainer.validateEnvFile("export OPENAI_API_KEY=sk"))
        XCTAssertThrowsError(try WorkerContainer.validateEnvFile("1KEY=x"))
        XCTAssertThrowsError(try WorkerContainer.validateEnvFile("KEY='x'"))
    }

    func testShellQuoteAndNames() {
        XCTAssertEqual(shellQuote("it's; rm -rf /"), #"'it'\''s; rm -rf /'"#)
        XCTAssertNoThrow(try WorkerNames.validate(name: "team-a-1"))
        for bad in ["", "-a", "a-", "A", "a_b", "a/b", String(repeating: "a", count: 41)] {
            XCTAssertThrowsError(try WorkerNames.validate(name: bad), bad)
        }
        XCTAssertThrowsError(try WorkerNames.validate(owner: "a:b"))
    }

    func testChildThatIgnoresStdinDoesNotKillUs() async throws {
        // `true` exits without reading, so writing 8 MB to its stdin hits a closed pipe.
        let output = try await ProcessCommandRunner().run("true", [], stdin: Data(count: 8 << 20))
        XCTAssertEqual(output.status, 0)
    }

    func testFleetFileIsOwnerOnly() throws {
        try store.save(FleetRegistry())
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testSetupScriptInstallsOnlyDocker() {
        let script = HostBootstrap.script
        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("apt-get -o DPkg::Lock::Timeout=600 install -y --no-install-recommends docker.io"))
        XCTAssertTrue(script.contains("systemctl enable --now docker"))
        XCTAssertTrue(script.contains("ufw --force enable"))
        XCTAssertFalse(script.contains("API_KEY"))
    }
}
