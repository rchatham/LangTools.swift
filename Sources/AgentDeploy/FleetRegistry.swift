//
//  FleetRegistry.swift
//  AgentDeploy
//
//  The operator's record of hosts and which host each worker is on, kept in
//  ~/.config/langtools-agent/fleet.json. The containers themselves carry labels, so
//  `list` can rediscover workers if this file is lost; hosts must be added again.
//

import Foundation

public struct HostRecord: Codable, Equatable {
    public enum Kind: String, Codable {
        /// The machine running the deploy tool.
        case local
        /// Any machine reachable over SSH with Docker installed.
        case ssh
    }

    public var name: String
    public var kind: Kind
    /// `user@host` for SSH hosts.
    public var address: String?
    public var port: Int?
    public var identityFile: String?
    /// Set when the host is dedicated to one owner; it then only runs that owner's workers.
    public var owner: String?
    /// The provider that created the machine, such as `digitalocean`, if any.
    public var provider: String?
    /// The provider's ID for the machine, used by `host destroy`.
    public var machineID: String?

    public init(name: String, kind: Kind, address: String? = nil, port: Int? = nil, identityFile: String? = nil, owner: String? = nil, provider: String? = nil, machineID: String? = nil) {
        self.name = name
        self.kind = kind
        self.address = address
        self.port = port
        self.identityFile = identityFile
        self.owner = owner
        self.provider = provider
        self.machineID = machineID
    }

    public static let local = HostRecord(name: "local", kind: .local)
}

public struct WorkerRecord: Codable, Equatable {
    public var name: String
    public var host: String
    public var owner: String?

    public init(name: String, host: String, owner: String? = nil) {
        self.name = name
        self.host = host
        self.owner = owner
    }
}

public struct FleetRegistry: Codable, Equatable {
    /// Hosts other than `local`, which always exists.
    public var hosts: [HostRecord]
    public var workers: [WorkerRecord]

    public init(hosts: [HostRecord] = [], workers: [WorkerRecord] = []) {
        self.hosts = hosts
        self.workers = workers
    }

    public var allHosts: [HostRecord] { [.local] + hosts.filter { $0.name != HostRecord.local.name } }

    public func host(named name: String) throws -> HostRecord {
        guard let host = allHosts.first(where: { $0.name == name }) else {
            throw DeployError.invalidArgument("No host named '\(name)'. Add one with `langtools-agent-deploy host add`.")
        }
        return host
    }

    public func worker(named name: String) throws -> WorkerRecord {
        guard let worker = workers.first(where: { $0.name == name }) else { throw DeployError.workerNotFound(name) }
        return worker
    }

    public mutating func upsert(_ worker: WorkerRecord) {
        workers.removeAll { $0.name == worker.name }
        workers.append(worker)
        workers.sort { $0.name < $1.name }
    }

    public mutating func upsert(_ host: HostRecord) {
        hosts.removeAll { $0.name == host.name }
        hosts.append(host)
        hosts.sort { $0.name < $1.name }
    }
}

/// Loads and saves the registry file.
public struct FleetStore {
    public var file: URL

    public init(file: URL) {
        self.file = file
    }

    public static func defaultDirectory(environment: [String: String]) -> URL {
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".config", isDirectory: true)
        return config.appendingPathComponent("langtools-agent", isDirectory: true)
    }

    public func load() throws -> FleetRegistry {
        guard FileManager.default.fileExists(atPath: file.path) else { return FleetRegistry() }
        do { return try JSONDecoder().decode(FleetRegistry.self, from: Data(contentsOf: file)) }
        catch { throw DeployError.unexpectedOutput("Could not read \(file.path): \(error)") }
    }

    public func save(_ registry: FleetRegistry) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: file, options: .atomic)
    }
}
