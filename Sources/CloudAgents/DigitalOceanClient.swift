//
//  DigitalOceanClient.swift
//  LangTools
//
//  Created by Claude on 2025.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for interacting with DigitalOcean API v2
public struct DigitalOceanClient: Sendable {
    private let apiToken: String
    private let baseURL = URL(string: "https://api.digitalocean.com/v2")!

    public init(apiToken: String) {
        self.apiToken = apiToken
    }

    // MARK: - Droplet Management

    /// Creates a new droplet with the specified configuration
    public func createDroplet(_ request: CreateDropletRequest) async throws -> Droplet {
        let url = baseURL.appendingPathComponent("droplets")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DigitalOceanError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8)
            throw DigitalOceanError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let createResponse = try JSONDecoder().decode(CreateDropletResponse.self, from: data)
        return createResponse.droplet
    }

    /// Retrieves information about a specific droplet
    public func getDroplet(id: Int) async throws -> Droplet {
        let url = baseURL.appendingPathComponent("droplets/\(id)")
        var urlRequest = URLRequest(url: url)
        urlRequest.addValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DigitalOceanError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8)
            throw DigitalOceanError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let dropletResponse = try JSONDecoder().decode(DropletResponse.self, from: data)
        return dropletResponse.droplet
    }

    /// Deletes a droplet
    public func deleteDroplet(id: Int) async throws {
        let url = baseURL.appendingPathComponent("droplets/\(id)")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "DELETE"
        urlRequest.addValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DigitalOceanError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8)
            throw DigitalOceanError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }
    }

    /// Lists all droplets with optional tag filtering
    public func listDroplets(tag: String? = nil) async throws -> [Droplet] {
        var components = URLComponents(url: baseURL.appendingPathComponent("droplets"), resolvingAgainstBaseURL: false)!
        if let tag = tag {
            components.queryItems = [URLQueryItem(name: "tag_name", value: tag)]
        }

        guard let url = components.url else {
            throw DigitalOceanError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.addValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DigitalOceanError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8)
            throw DigitalOceanError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let listResponse = try JSONDecoder().decode(ListDropletsResponse.self, from: data)
        return listResponse.droplets
    }

    /// Performs a droplet action (power on, power off, reboot, etc.)
    public func performAction(dropletId: Int, action: DropletAction) async throws -> Action {
        let url = baseURL.appendingPathComponent("droplets/\(dropletId)/actions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(["type": action.rawValue])

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DigitalOceanError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8)
            throw DigitalOceanError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let actionResponse = try JSONDecoder().decode(ActionResponse.self, from: data)
        return actionResponse.action
    }
}

// MARK: - Request Models

public struct CreateDropletRequest: Codable, Sendable {
    public let name: String
    public let region: String
    public let size: String
    public let image: String
    public let ssh_keys: [String]
    public let backups: Bool
    public let ipv6: Bool
    public let user_data: String?
    public let private_networking: Bool
    public let volumes: [String]?
    public let tags: [String]

    public init(
        name: String,
        region: String = "nyc3",
        size: String = "s-1vcpu-1gb",
        image: String = "ubuntu-22-04-x64",
        ssh_keys: [String] = [],
        backups: Bool = false,
        ipv6: Bool = true,
        user_data: String? = nil,
        private_networking: Bool = false,
        volumes: [String]? = nil,
        tags: [String] = ["langtools", "agent-runtime"]
    ) {
        self.name = name
        self.region = region
        self.size = size
        self.image = image
        self.ssh_keys = ssh_keys
        self.backups = backups
        self.ipv6 = ipv6
        self.user_data = user_data
        self.private_networking = private_networking
        self.volumes = volumes
        self.tags = tags
    }
}

// MARK: - Response Models

public struct CreateDropletResponse: Codable, Sendable {
    public let droplet: Droplet
}

public struct DropletResponse: Codable, Sendable {
    public let droplet: Droplet
}

public struct ListDropletsResponse: Codable, Sendable {
    public let droplets: [Droplet]
}

public struct ActionResponse: Codable, Sendable {
    public let action: Action
}

// MARK: - Data Models

public struct Droplet: Codable, Sendable {
    public let id: Int
    public let name: String
    public let memory: Int
    public let vcpus: Int
    public let disk: Int
    public let locked: Bool
    public let status: String
    public let created_at: String
    public let features: [String]
    public let size_slug: String
    public let networks: Networks
    public let region: Region
    public let tags: [String]

    public struct Networks: Codable, Sendable {
        public let v4: [NetworkInterface]
        public let v6: [NetworkInterface]

        public struct NetworkInterface: Codable, Sendable {
            public let ip_address: String
            public let netmask: String
            public let gateway: String
            public let type: String
        }
    }

    public struct Region: Codable, Sendable {
        public let name: String
        public let slug: String
        public let features: [String]
        public let available: Bool
        public let sizes: [String]
    }

    /// Returns the public IPv4 address if available
    public var publicIPv4: String? {
        networks.v4.first(where: { $0.type == "public" })?.ip_address
    }

    /// Returns the private IPv4 address if available
    public var privateIPv4: String? {
        networks.v4.first(where: { $0.type == "private" })?.ip_address
    }
}

public struct Action: Codable, Sendable {
    public let id: Int
    public let status: String
    public let type: String
    public let started_at: String
    public let completed_at: String?
    public let resource_id: Int
    public let resource_type: String
    public let region_slug: String?
}

public enum DropletAction: String, Codable, Sendable {
    case powerOn = "power_on"
    case powerOff = "power_off"
    case shutdown = "shutdown"
    case reboot = "reboot"
    case enableBackups = "enable_backups"
    case disableBackups = "disable_backups"
    case enableIPv6 = "enable_ipv6"
}

// MARK: - Errors

public enum DigitalOceanError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String?)
    case invalidURL
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from DigitalOcean API"
        case .apiError(let statusCode, let message):
            return "DigitalOcean API error (HTTP \(statusCode)): \(message ?? "Unknown error")"
        case .invalidURL:
            return "Invalid URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
