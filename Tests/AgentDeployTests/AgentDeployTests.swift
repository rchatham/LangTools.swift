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
        /// The remote command for ssh calls, the whole command line otherwise.
        var command: String { executable == "ssh" ? (arguments.last ?? "") : ([executable] + arguments).joined(separator: " ") }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var handlers: [(match: (Call) -> Bool, respond: (Call) -> CommandOutput)] = []

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    func calls(_ executable: String) -> [Call] { calls.filter { $0.executable == executable } }

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
    private var files: [String: Data] = [:]
    private var output: [String] = []
    private var errors: [String] = []
    private var stdin = Data()
    private var temp: URL!

    private let specJSON = #"{"name": "Helper", "instructions": "Answer.", "provider": "openai", "model": "gpt-4o", "messages": [{"role": "user", "content": "Ping"}]}"#

    override func setUp() {
        super.setUp()
        runner = FakeRunner()
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("deploy-\(UUID().uuidString)", isDirectory: true)
        files = [
            "worker.env": Data("OPENAI_API_KEY=sk-test\nLANGTOOLS_WEBHOOK_SECRET=whsec\n".utf8),
            "spec.json": Data(specJSON.utf8),
        ]
        output = []
        errors = []
        stdin = Data()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    private func command(environment: [String: String] = [:]) -> AgentDeployCommand {
        var compute = DigitalOceanCompute(runner: runner)
        compute.writeTemporaryFile = { contents in
            let url = self.temp.appendingPathComponent("user-data.sh")
            try FileManager.default.createDirectory(at: self.temp, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            return url
        }
        compute.removeFile = { _ in }  // Kept so the test can read it.
        var command = AgentDeployCommand(
            compute: compute, runner: runner, environment: environment,
            knownHostsFile: temp.appendingPathComponent("known_hosts"),
            readFile: { path in
                guard let data = self.files[path] else { throw CocoaError(.fileNoSuchFile) }
                return data
            },
            standardInput: { self.stdin },
            standardOutput: { self.output.append($0) },
            standardError: { self.errors.append($0) }
        )
        command.sleep = { _ in }
        return command
    }

    /// A droplet as doctl prints it: godo's Droplet with empty fields omitted.
    private func dropletJSON(id: Int = 4242, worker: String, owner: String? = nil, ip: String? = "203.0.113.7", status: String = "active") -> String {
        var tags = ["\"langtools-agent\"", "\"langtools-agent-worker:\(worker)\""]
        if let owner { tags.append("\"langtools-agent-owner:\(owner)\"") }
        let networks = ip.map { #","networks":{"v4":[{"ip_address":"10.10.0.5","netmask":"255.255.0.0","gateway":"10.10.0.1","type":"private"},{"ip_address":"\#($0)","netmask":"255.255.240.0","gateway":"203.0.113.1","type":"public"}],"v6":[{"ip_address":"2604:a880::1","netmask":64,"gateway":"2604:a880::","type":"public"}]}"# } ?? ""
        return #"{"id":\#(id),"name":"langtools-agent-\#(worker)","memory":1024,"vcpus":1,"disk":25,"region":{"slug":"nyc3","name":"New York 3","sizes":["s-1vcpu-1gb"],"available":true,"features":["metadata"]},"size_slug":"s-1vcpu-1gb","locked":false,"status":"\#(status)"\#(networks),"created_at":"2026-10-28T03:00:00Z","tags":[\#(tags.joined(separator: ","))],"volume_ids":[],"vpc_uuid":"5a4981aa-0000-0000-0000-000000000000"}"#
    }

    private func givenWorkers(_ droplets: String...) {
        runner.on("compute droplet list", stdout: "[\(droplets.joined(separator: ","))]")
    }

    // MARK: - doctl

    func testListParsesDropletsAndIgnoresUntaggedOnes() async throws {
        let untagged = #"{"id":1,"name":"other","status":"active","tags":["langtools-agent"]}"#
        givenWorkers(dropletJSON(worker: "shared"), dropletJSON(id: 7, worker: "alice-box", owner: "alice", ip: nil, status: "new"), untagged)
        let status = await command().run(["list"])
        XCTAssertEqual(status, 0, errors.joined())
        XCTAssertEqual(output, [
            "NAME\tOWNER\tSTATUS\tIP\tREGION\tSIZE",
            "alice-box\talice\tnew\t-\tnyc3\ts-1vcpu-1gb",
            "shared\t(shared)\tactive\t203.0.113.7\tnyc3\ts-1vcpu-1gb",
        ])
        XCTAssertEqual(runner.calls("doctl").first?.arguments, ["compute", "droplet", "list", "--tag-name", "langtools-agent", "--output", "json"])
    }

    func testEmptyDoctlOutputMeansNoWorkers() async throws {
        runner.on("compute droplet list", stdout: "\n")
        let workers = try await DigitalOceanCompute(runner: runner).workers()
        XCTAssertEqual(workers, [])
    }

    func testDoctlJSONErrorIsReported() async {
        runner.on("compute droplet list", status: 1, stdout: #"{"errors":[{"detail":"Unable to initialize DigitalOcean API client: access token is required. (hint: run 'doctl auth init')"}]}"#)
        let status = await command().run(["list"])
        XCTAssertEqual(status, 1)
        XCTAssertEqual(errors, ["error: doctl exited with status 1: Unable to initialize DigitalOcean API client: access token is required. (hint: run 'doctl auth init')"])
        XCTAssertEqual(runner.calls("doctl").count, 1, "A failed command is never re-run")
    }

    func testDoctlContextIsPassed() async throws {
        runner.on("compute droplet list", stdout: "[]")
        _ = try await DigitalOceanCompute(runner: runner, context: "work").workers()
        XCTAssertEqual(runner.calls("doctl").first?.arguments.suffix(2), ["--context", "work"])
    }

    // MARK: - create

    private func givenHealthyBoot() {
        runner.on("compute ssh-key list", stdout: #"[{"id":111,"name":"laptop","fingerprint":"aa:bb"},{"id":222,"name":"ci","fingerprint":"cc:dd"}]"#)
        runner.on("compute droplet create", stdout: "[\(dropletJSON(worker: "w1", owner: "alice"))]")
        runner.on("cloud-init status --wait", stdout: "status: done")
        runner.on("cat /etc/langtools-agent/worker.conf", status: 1)
    }

    func testCreateProvisionsIsolatedWorker() async throws {
        runner.on("compute droplet list", stdout: "[]")
        givenHealthyBoot()
        var sshAttempts = 0
        runner.on({ $0.command == "true" }) { _ in
            sshAttempts += 1
            return CommandOutput(status: sshAttempts < 3 ? 255 : 0, stderr: Data("Connection refused".utf8))
        }

        let status = await command().run(["create", "w1", "--owner", "alice", "--image", "registry.digitalocean.com/acme/langtools-agent:1.0", "--env-file", "worker.env", "--region", "sfo3", "--concurrency", "4"])

        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        let create = try XCTUnwrap(runner.calls("doctl").first { $0.arguments.starts(with: ["compute", "droplet", "create"]) })
        XCTAssertEqual(create.arguments, [
            "compute", "droplet", "create", "langtools-agent-w1",
            "--region", "sfo3", "--size", "s-1vcpu-1gb", "--image", "ubuntu-24-04-x64",
            "--ssh-keys", "111,222",
            "--tag-names", "langtools-agent,langtools-agent-worker:w1,langtools-agent-owner:alice",
            "--user-data-file", temp.appendingPathComponent("user-data.sh").path,
            "--enable-monitoring", "--wait", "--output", "json",
        ])
        let userData = try String(contentsOf: temp.appendingPathComponent("user-data.sh"))
        XCTAssertEqual(userData, WorkerProvisioning.userDataScript)
        XCTAssertFalse(userData.contains("sk-test"), "Secrets must not go in user data")
        XCTAssertEqual(sshAttempts, 3, "Retries SSH until the droplet accepts it")

        // Keys, registry credentials and config go over SSH, on stdin.
        let ssh = runner.calls("ssh")
        XCTAssertTrue(ssh.allSatisfy { $0.arguments.contains("root@203.0.113.7") && $0.arguments.contains("StrictHostKeyChecking=accept-new") && $0.arguments.contains("BatchMode=yes") })
        let envUpload = try XCTUnwrap(ssh.first { $0.command.contains("/etc/langtools-agent/env") })
        XCTAssertEqual(envUpload.command, "umask 077 && cat > '/etc/langtools-agent/env.new' && mv -f '/etc/langtools-agent/env.new' '/etc/langtools-agent/env'")
        XCTAssertEqual(envUpload.stdin, files["worker.env"])
        XCTAssertTrue(ssh.contains { $0.command.contains("/etc/langtools-agent/docker/config.json") }, "DOCR image needs registry credentials")
        XCTAssertTrue(runner.calls("doctl").contains { $0.arguments == ["registry", "docker-config"] })
        let conf = try XCTUnwrap(ssh.first { $0.command.contains("worker.conf.new") })
        XCTAssertEqual(conf.stdin.map { String(decoding: $0, as: UTF8.self) }, "IMAGE=registry.digitalocean.com/acme/langtools-agent:1.0\nCONCURRENCY=4\n")
        XCTAssertTrue(ssh.contains { $0.command == "systemctl restart langtools-agent" })
        XCTAssertFalse(ssh.contains { $0.arguments.joined(separator: " ").contains("sk-test") }, "Secrets never appear in arguments")
        XCTAssertEqual(output, ["w1\t203.0.113.7\tready"])
    }

    func testCreateChecksEverythingLocalBeforeSpending() async {
        runner.on("compute droplet list", stdout: "[\(dropletJSON(worker: "taken"))]")
        files["noKeys.env"] = Data("LANGTOOLS_WEBHOOK_SECRET=x\n".utf8)
        files["quoted.env"] = Data("OPENAI_API_KEY=\"sk-test\"\n".utf8)
        let cases: [[String]] = [
            ["create", "Bad_Name", "--image", "img", "--env-file", "worker.env"],
            ["create", "w1", "--image", "img; rm -rf /", "--env-file", "worker.env"],
            ["create", "w1", "--image", "img", "--env-file", "missing.env"],
            ["create", "w1", "--image", "img", "--env-file", "noKeys.env"],
            ["create", "w1", "--image", "img", "--env-file", "quoted.env"],
            ["create", "w1", "--image", "img", "--env-file", "worker.env", "--owner", "bad owner"],
            ["create", "w1", "--env-file", "worker.env"],
            ["create", "taken", "--image", "img", "--env-file", "worker.env"],
        ]
        for arguments in cases {
            let status = await command().run(arguments)
            XCTAssertNotEqual(status, 0, "\(arguments)")
        }
        XCTAssertFalse(runner.calls("doctl").contains { $0.arguments.starts(with: ["compute", "droplet", "create"]) }, "No droplet may be created")
        XCTAssertTrue(errors.contains { $0.contains("remove the quotes") }, "\(errors)")
    }

    func testCreateReportsFailedFirstBootAndHowToClean() async {
        runner.on("compute droplet list", stdout: "[]")
        givenHealthyBoot()
        runner.on("cloud-init status --wait", status: 1, stdout: "status: error")
        let status = await command().run(["create", "w1", "--image", "img", "--env-file", "worker.env"])
        XCTAssertEqual(status, 1)
        XCTAssertTrue(errors.contains { $0.contains("First-boot setup failed") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("destroy w1 --force") }, "\(errors)")
        XCTAssertFalse(runner.calls("ssh").contains { $0.command.contains("/etc/langtools-agent/env") }, "Keys are not uploaded to a broken droplet")
    }

    // MARK: - configure

    func testConfigureKeepsCurrentImageAndConcurrency() async throws {
        givenWorkers(dropletJSON(worker: "w1"))
        runner.on("cat /etc/langtools-agent/worker.conf", stdout: "IMAGE=ghcr.io/acme/langtools-agent:2\nCONCURRENCY=6\n")
        let status = await command().run(["configure", "w1", "--env-file", "worker.env"])
        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        let conf = try XCTUnwrap(runner.calls("ssh").first { $0.command.contains("worker.conf.new") })
        XCTAssertEqual(conf.stdin.map { String(decoding: $0, as: UTF8.self) }, "IMAGE=ghcr.io/acme/langtools-agent:2\nCONCURRENCY=6\n")
        XCTAssertFalse(runner.calls("doctl").contains { $0.arguments.first == "registry" }, "Non-DOCR images need no credentials")
    }

    // MARK: - submit

    func testSubmitSendsJobOnStandardInput() async throws {
        givenWorkers(dropletJSON(worker: "shared"))
        runner.on("enqueue --job", stdout: #"{"runID" : "r-1", "state" : "queued"}"#)

        let status = await command(environment: ["LANGTOOLS_WEBHOOK_SECRET": "job-secret"])
            .run(["submit", "shared", "spec.json", "--webhook", "https://example.com/h", "--run-id", "r-1", "--owner", "bob"])

        XCTAssertEqual(status, 0, errors.joined(separator: "\n"))
        let call = try XCTUnwrap(runner.calls("ssh").last)
        XCTAssertEqual(call.command, "docker exec -i langtools-agent langtools-agent enqueue --job --spool /spool")
        let job = try AgentJob.decode(from: XCTUnwrap(call.stdin))
        XCTAssertEqual(job.runID, "r-1")
        XCTAssertEqual(job.owner, "bob")
        XCTAssertEqual(job.webhookSecret, "job-secret")
        XCTAssertEqual(job.webhookURL?.absoluteString, "https://example.com/h")
        XCTAssertEqual(job.spec.name, "Helper")
        XCTAssertFalse(call.arguments.joined().contains("job-secret"))
        XCTAssertEqual(output, [#"{"runID" : "r-1", "state" : "queued"}"#])
    }

    func testIsolatedWorkerOnlyTakesItsOwnersJobs() async {
        givenWorkers(dropletJSON(worker: "alice-box", owner: "alice"))
        let noOwner = await command().run(["submit", "alice-box", "spec.json"])
        XCTAssertEqual(noOwner, 2)
        let otherOwner = await command().run(["submit", "alice-box", "spec.json", "--owner", "bob"])
        XCTAssertEqual(otherOwner, 2)
        XCTAssertTrue(errors.contains { $0.contains("isolated for owner 'alice'") }, "\(errors)")
        XCTAssertTrue(runner.calls("ssh").isEmpty, "Nothing reaches the worker")

        runner.on("enqueue --job", stdout: "{}")
        let owner = await command().run(["submit", "alice-box", "spec.json", "--owner", "alice"])
        XCTAssertEqual(owner, 0)
    }

    func testSubmitRejectsBadJobsLocally() async {
        givenWorkers(dropletJSON(worker: "shared"))
        files["bad.json"] = Data(#"{"name": "x"}"#.utf8)
        let badSpec = await command().run(["submit", "shared", "bad.json"])
        XCTAssertEqual(badSpec, 1)
        let insecure = await command().run(["submit", "shared", "spec.json", "--webhook", "http://example.com/h"])
        XCTAssertEqual(insecure, 2)
        let badID = await command().run(["submit", "shared", "spec.json", "--run-id", "../x"])
        XCTAssertEqual(badID, 2)
        let missing = await command().run(["submit", "nope", "spec.json"])
        XCTAssertEqual(missing, 1)
        XCTAssertTrue(errors.contains { $0.contains("No worker named 'nope'") }, "\(errors)")
        XCTAssertTrue(runner.calls("ssh").isEmpty)
    }

    // MARK: - status, logs, destroy

    func testStatusQuotesRunIDAndPassesExitStatus() async throws {
        givenWorkers(dropletJSON(worker: "shared"))
        runner.on("langtools-agent status", status: 1, stdout: #"{"runID":"r-9","state":"unknown"}"#)
        let status = await command().run(["status", "shared", "r-9"])
        XCTAssertEqual(status, 1)
        XCTAssertEqual(runner.calls("ssh").last?.command, "docker exec langtools-agent langtools-agent status --spool /spool 'r-9'")
        let injection = await command().run(["status", "shared", "x;reboot"])
        XCTAssertEqual(injection, 2)
    }

    func testLogs() async {
        givenWorkers(dropletJSON(worker: "shared"))
        runner.on("journalctl", stdout: "worker started\n")
        let status = await command().run(["logs", "shared", "--lines", "50"])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(runner.calls("ssh").last?.command, "journalctl -u langtools-agent --no-pager -n 50")
        XCTAssertEqual(output, ["worker started"])
    }

    func testDestroyRequiresForce() async {
        givenWorkers(dropletJSON(id: 99, worker: "old"))
        let unconfirmed = await command().run(["destroy", "old"])
        XCTAssertEqual(unconfirmed, 2)
        XCTAssertFalse(runner.calls("doctl").contains { $0.arguments.contains("delete") })

        let confirmed = await command().run(["destroy", "old", "--force"])
        XCTAssertEqual(confirmed, 0)
        XCTAssertTrue(runner.calls("doctl").contains { $0.arguments == ["compute", "droplet", "delete", "99", "--force"] })
    }

    // MARK: - Pieces

    func testEnvFileValidation() throws {
        XCTAssertEqual(try WorkerProvisioning.validateEnvFile("# keys\nOPENAI_API_KEY=sk-1\n\nX_2=a=b\n"), ["OPENAI_API_KEY", "X_2"])
        XCTAssertThrowsError(try WorkerProvisioning.validateEnvFile("export OPENAI_API_KEY=sk"))
        XCTAssertThrowsError(try WorkerProvisioning.validateEnvFile("1KEY=x"))
        XCTAssertThrowsError(try WorkerProvisioning.validateEnvFile("KEY='x'"))
    }

    func testShellQuote() {
        XCTAssertEqual(shellQuote("plain"), "'plain'")
        XCTAssertEqual(shellQuote("it's; rm -rf /"), #"'it'\''s; rm -rf /'"#)
    }

    func testNames() {
        XCTAssertNoThrow(try WorkerNames.validate(name: "team-a-1"))
        for bad in ["", "-a", "a-", "A", "a_b", String(repeating: "a", count: 41)] {
            XCTAssertThrowsError(try WorkerNames.validate(name: bad), bad)
        }
        XCTAssertNoThrow(try WorkerNames.validate(owner: "Alice_01"))
        XCTAssertThrowsError(try WorkerNames.validate(owner: "a:b"))
    }

    func testUserDataInstallsServiceThatWaitsForConfig() {
        let script = WorkerProvisioning.userDataScript
        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("ConditionPathExists=/etc/langtools-agent/env"))
        XCTAssertTrue(script.contains("install -d -m 0700 -o 10001 -g 10001 /var/lib/langtools-agent"))
        XCTAssertTrue(script.contains("--cap-drop ALL"))
        XCTAssertTrue(script.contains("ufw --force enable"))
    }
}
