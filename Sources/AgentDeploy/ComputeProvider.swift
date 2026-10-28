//
//  ComputeProvider.swift
//  AgentDeploy
//
//  Creates, finds and deletes the machines workers run on. A worker is one machine
//  running the langtools-agent container. A shared worker takes jobs from anyone the
//  operator lets submit; an isolated worker belongs to one owner, with its own
//  machine, API keys and queue.
//

import Foundation

public struct WorkerHost: Equatable {
    /// The provider's machine ID.
    public var id: String
    public var name: String
    /// Set for an isolated worker.
    public var owner: String?
    public var status: String
    public var publicIPv4: String?
    public var region: String?
    public var size: String?

    public init(id: String, name: String, owner: String? = nil, status: String, publicIPv4: String? = nil, region: String? = nil, size: String? = nil) {
        self.id = id
        self.name = name
        self.owner = owner
        self.status = status
        self.publicIPv4 = publicIPv4
        self.region = region
        self.size = size
    }

    public var isIsolated: Bool { owner != nil }
}

public struct WorkerRequest: Equatable {
    public var name: String
    public var owner: String?
    public var region: String
    public var size: String
    /// SSH key IDs or fingerprints; empty means every key on the account.
    public var sshKeys: [String]
    /// Runs on first boot to install Docker and the worker service.
    public var userData: String

    public init(name: String, owner: String?, region: String, size: String, sshKeys: [String], userData: String) {
        self.name = name
        self.owner = owner
        self.region = region
        self.size = size
        self.sshKeys = sshKeys
        self.userData = userData
    }
}

public protocol ComputeProvider {
    var displayName: String { get }
    /// Creates the machine and returns once it has a public address.
    func createWorker(_ request: WorkerRequest) async throws -> WorkerHost
    func workers() async throws -> [WorkerHost]
    func deleteWorker(_ worker: WorkerHost) async throws
    /// A Docker `config.json` that can pull `image`, or nil when the image needs no login.
    func registryCredentials(for image: String) async throws -> Data?
}

extension ComputeProvider {
    public func worker(named name: String) async throws -> WorkerHost {
        guard let worker = try await workers().first(where: { $0.name == name }) else { throw DeployError.workerNotFound(name) }
        return worker
    }
}

public enum WorkerNames {
    /// Worker names become machine host names: lowercase letters, digits and `-`, up to 40 characters.
    public static func validate(name: String) throws {
        guard (1...40).contains(name.count), !name.hasPrefix("-"), !name.hasSuffix("-"),
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
        else { throw DeployError.invalidArgument("Worker name '\(name)' must be 1-40 lowercase letters, digits or '-', not starting or ending with '-'.") }
    }

    /// Owners go into tags: letters, digits, `_` and `-`, up to 64 characters.
    public static func validate(owner: String) throws {
        guard (1...64).contains(owner.count),
              owner.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") })
        else { throw DeployError.invalidArgument("Owner '\(owner)' must be 1-64 letters, digits, '_' or '-'.") }
    }
}
