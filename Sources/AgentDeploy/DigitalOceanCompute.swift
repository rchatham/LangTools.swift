//
//  DigitalOceanCompute.swift
//  AgentDeploy
//
//  Runs workers on DigitalOcean droplets through `doctl`, so the deploy tool uses
//  doctl's own authentication and never handles an API token itself.
//

import Foundation

public struct DigitalOceanCompute: ComputeProvider {
    public static let baseTag = "langtools-agent"
    static let workerTagPrefix = "langtools-agent-worker:"
    static let ownerTagPrefix = "langtools-agent-owner:"
    public static let image = "ubuntu-24-04-x64"
    static let registryHost = "registry.digitalocean.com"

    public var displayName: String { "DigitalOcean" }
    public var runner: CommandRunner
    /// `doctl` executable name or path.
    public var doctl: String
    /// Passed as `--context` when set, to pick one of several doctl accounts.
    public var context: String?
    var writeTemporaryFile: (String) throws -> URL = DigitalOceanCompute.writeTemporaryFile
    var removeFile: (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }

    public init(runner: CommandRunner, doctl: String = "doctl", context: String? = nil) {
        self.runner = runner
        self.doctl = doctl
        self.context = context
    }

    public func createWorker(_ request: WorkerRequest) async throws -> WorkerHost {
        try WorkerNames.validate(name: request.name)
        if let owner = request.owner { try WorkerNames.validate(owner: owner) }
        let keys = request.sshKeys.isEmpty ? try await accountSSHKeys() : request.sshKeys
        guard !keys.isEmpty else { throw DeployError.invalidArgument("No SSH keys on the DigitalOcean account. Add one with `doctl compute ssh-key import`, or pass --ssh-key.") }

        var tags = [Self.baseTag, Self.workerTagPrefix + request.name]
        if let owner = request.owner { tags.append(Self.ownerTagPrefix + owner) }

        let userDataFile = try writeTemporaryFile(request.userData)
        defer { removeFile(userDataFile) }
        let output = try await doctl([
            "compute", "droplet", "create", Self.dropletName(for: request.name),
            "--region", request.region,
            "--size", request.size,
            "--image", Self.image,
            "--ssh-keys", keys.joined(separator: ","),
            "--tag-names", tags.joined(separator: ","),
            "--user-data-file", userDataFile.path,
            "--enable-monitoring",
            "--wait",
        ])
        guard let worker = try Self.decodeDroplets(output.stdout).first.flatMap(Self.worker(from:)) else {
            throw DeployError.unexpectedOutput("doctl did not return the new droplet.")
        }
        return worker
    }

    public func workers() async throws -> [WorkerHost] {
        let output = try await doctl(["compute", "droplet", "list", "--tag-name", Self.baseTag])
        return try Self.decodeDroplets(output.stdout).compactMap(Self.worker(from:)).sorted { $0.name < $1.name }
    }

    public func deleteWorker(_ worker: WorkerHost) async throws {
        _ = try await doctl(["compute", "droplet", "delete", worker.id, "--force"], json: false)
    }

    /// Read-only credentials for DigitalOcean Container Registry images; other registries need none.
    public func registryCredentials(for image: String) async throws -> Data? {
        guard image.hasPrefix(Self.registryHost + "/") else { return nil }
        return try await doctl(["registry", "docker-config"], json: false).stdout
    }

    static func dropletName(for worker: String) -> String { "langtools-agent-\(worker)" }

    private func accountSSHKeys() async throws -> [String] {
        let output = try await doctl(["compute", "ssh-key", "list"])
        struct Key: Decodable { var id: Int? }
        return try JSONDecoder().decode([Key].self, from: Self.nonEmpty(output.stdout)).compactMap { $0.id.map(String.init) }
    }

    private func doctl(_ arguments: [String], json: Bool = true) async throws -> CommandOutput {
        var arguments = arguments
        if json { arguments += ["--output", "json"] }
        if let context { arguments += ["--context", context] }
        let output = try await runner.run(doctl, arguments, stdin: nil)
        if output.status == 127, output.stderrString.hasPrefix("/usr/bin/env:") {
            throw DeployError.invalidArgument("Could not find `\(doctl)`. Install doctl and run `doctl auth init`.")
        }
        guard output.status == 0 else {
            throw DeployError.commandFailed(executable: doctl, status: output.status, message: output.stderrString.isEmpty ? Self.errorDetail(output.stdout) : output.stderrString)
        }
        return output
    }

    // With --output json, doctl reports errors as JSON on stdout rather than stderr.
    static func errorDetail(_ stdout: Data) -> String {
        struct Errors: Decodable { struct Detail: Decodable { var detail: String? }; var errors: [Detail] }
        if let errors = try? JSONDecoder().decode(Errors.self, from: stdout) {
            return errors.errors.compactMap(\.detail).joined(separator: "; ")
        }
        return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // doctl prints nothing, not `[]`, for an empty list.
    private static func nonEmpty(_ data: Data) -> Data {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Data("[]".utf8) : data
    }

    /// The subset of godo's `Droplet` the deploy tool reads. doctl omits empty fields.
    struct Droplet: Decodable {
        struct Networks: Decodable {
            struct V4: Decodable { var ip_address: String?; var type: String? }
            var v4: [V4]?
        }
        struct Region: Decodable { var slug: String? }
        var id: Int
        var name: String?
        var status: String?
        var tags: [String]?
        var networks: Networks?
        var region: Region?
        var size_slug: String?
    }

    static func decodeDroplets(_ data: Data) throws -> [Droplet] {
        do { return try JSONDecoder().decode([Droplet].self, from: nonEmpty(data)) }
        catch { throw DeployError.unexpectedOutput("Could not read doctl's droplet list: \(error)") }
    }

    static func worker(from droplet: Droplet) -> WorkerHost? {
        let tags = droplet.tags ?? []
        guard let name = tags.first(where: { $0.hasPrefix(workerTagPrefix) })?.dropFirst(workerTagPrefix.count) else { return nil }
        return WorkerHost(
            id: String(droplet.id),
            name: String(name),
            owner: tags.first(where: { $0.hasPrefix(ownerTagPrefix) }).map { String($0.dropFirst(ownerTagPrefix.count)) },
            status: droplet.status ?? "unknown",
            publicIPv4: droplet.networks?.v4?.first(where: { $0.type == "public" })?.ip_address,
            region: droplet.region?.slug,
            size: droplet.size_slug
        )
    }

    private static func writeTemporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("langtools-agent-user-data-\(UUID().uuidString).sh")
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }
}
