//
//  ComputeProvider.swift
//  AgentDeploy
//
//  Creates and deletes machines to use as hosts. This is optional: any machine with
//  Docker that you can reach over SSH can be added as a host without a provider.
//

import Foundation

public struct Machine: Equatable {
    /// The provider's ID for the machine.
    public var id: String
    /// The host name it was created for.
    public var name: String
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
}

public struct MachineRequest: Equatable {
    public var name: String
    public var owner: String?
    public var region: String?
    public var size: String?
    /// SSH key IDs or fingerprints; empty lets the provider choose, such as every key on the account.
    public var sshKeys: [String]
    /// Runs on first boot; `HostBootstrap.script` installs Docker.
    public var userData: String

    public init(name: String, owner: String? = nil, region: String? = nil, size: String? = nil, sshKeys: [String] = [], userData: String = HostBootstrap.script) {
        self.name = name
        self.owner = owner
        self.region = region
        self.size = size
        self.sshKeys = sshKeys
        self.userData = userData
    }
}

public protocol ComputeProvider {
    /// Stored with each host it creates, such as `digitalocean`.
    var id: String { get }
    var displayName: String { get }
    /// The user to SSH in as on machines this provider creates.
    var sshUser: String { get }
    /// Creates the machine and returns once it has a public address.
    func createMachine(_ request: MachineRequest) async throws -> Machine
    func machines() async throws -> [Machine]
    func deleteMachine(id: String) async throws
    /// A Docker `config.json` that can pull `image`, or nil when the provider has no registry for it.
    func registryCredentials(for image: String) async throws -> Data?
}
