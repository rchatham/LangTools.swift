//
//  DigitalOceanClientTests.swift
//  LangTools
//
//  Created by Claude on 2025.
//

import XCTest
@testable import CloudAgents

final class DigitalOceanClientTests: XCTestCase {

    func testCreateDropletRequest() throws {
        let request = CreateDropletRequest(
            name: "test-droplet",
            region: "nyc3",
            size: "s-1vcpu-1gb"
        )

        XCTAssertEqual(request.name, "test-droplet")
        XCTAssertEqual(request.region, "nyc3")
        XCTAssertEqual(request.size, "s-1vcpu-1gb")
        XCTAssertEqual(request.tags, ["langtools", "agent-runtime"])
        XCTAssertTrue(request.ipv6)
        XCTAssertFalse(request.backups)
    }

    func testCreateDropletRequestWithCustomValues() throws {
        let request = CreateDropletRequest(
            name: "custom-droplet",
            region: "sfo3",
            size: "s-2vcpu-4gb",
            ssh_keys: ["key1", "key2"],
            backups: true,
            ipv6: false,
            user_data: "#!/bin/bash\necho hello",
            tags: ["custom", "test"]
        )

        XCTAssertEqual(request.name, "custom-droplet")
        XCTAssertEqual(request.region, "sfo3")
        XCTAssertEqual(request.size, "s-2vcpu-4gb")
        XCTAssertEqual(request.ssh_keys, ["key1", "key2"])
        XCTAssertTrue(request.backups)
        XCTAssertFalse(request.ipv6)
        XCTAssertEqual(request.user_data, "#!/bin/bash\necho hello")
        XCTAssertEqual(request.tags, ["custom", "test"])
    }

    func testDropletSizeEnum() {
        XCTAssertEqual(DropletSize.small.rawValue, "s-1vcpu-1gb")
        XCTAssertEqual(DropletSize.medium.rawValue, "s-1vcpu-2gb")
        XCTAssertEqual(DropletSize.large.rawValue, "s-2vcpu-2gb")
        XCTAssertEqual(DropletSize.xlarge.rawValue, "s-2vcpu-4gb")
    }

    func testDropletSizeDisplayName() {
        XCTAssertEqual(DropletSize.small.displayName, "Small (1 vCPU, 1 GB)")
        XCTAssertEqual(DropletSize.medium.displayName, "Medium (1 vCPU, 2 GB)")
        XCTAssertEqual(DropletSize.large.displayName, "Large (2 vCPU, 2 GB)")
        XCTAssertEqual(DropletSize.xlarge.displayName, "X-Large (2 vCPU, 4 GB)")
    }

    func testDropletSizeMonthlyCost() {
        XCTAssertEqual(DropletSize.small.monthlyCost, 6.0)
        XCTAssertEqual(DropletSize.medium.monthlyCost, 12.0)
        XCTAssertEqual(DropletSize.large.monthlyCost, 18.0)
        XCTAssertEqual(DropletSize.xlarge.monthlyCost, 24.0)
    }

    func testDropletSizeHourlyCost() {
        XCTAssertEqual(DropletSize.small.hourlyCost, 0.009)
        XCTAssertEqual(DropletSize.medium.hourlyCost, 0.018)
        XCTAssertEqual(DropletSize.large.hourlyCost, 0.027)
        XCTAssertEqual(DropletSize.xlarge.hourlyCost, 0.036)
    }

    func testDropletSizeCaseIterable() {
        let allSizes = DropletSize.allCases
        XCTAssertEqual(allSizes.count, 4)
        XCTAssertTrue(allSizes.contains(.small))
        XCTAssertTrue(allSizes.contains(.medium))
        XCTAssertTrue(allSizes.contains(.large))
        XCTAssertTrue(allSizes.contains(.xlarge))
    }

    func testCreateDropletRequestEncoding() throws {
        let request = CreateDropletRequest(
            name: "test-droplet",
            region: "nyc3",
            size: "s-1vcpu-1gb"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["name"] as? String, "test-droplet")
        XCTAssertEqual(json?["region"] as? String, "nyc3")
        XCTAssertEqual(json?["size"] as? String, "s-1vcpu-1gb")
    }

    func testDropletActionEnum() {
        XCTAssertEqual(DropletAction.powerOn.rawValue, "power_on")
        XCTAssertEqual(DropletAction.powerOff.rawValue, "power_off")
        XCTAssertEqual(DropletAction.shutdown.rawValue, "shutdown")
        XCTAssertEqual(DropletAction.reboot.rawValue, "reboot")
    }

    func testDigitalOceanErrorDescription() {
        let invalidResponse = DigitalOceanError.invalidResponse
        XCTAssertEqual(invalidResponse.errorDescription, "Invalid response from DigitalOcean API")

        let apiError = DigitalOceanError.apiError(statusCode: 404, message: "Not found")
        XCTAssertEqual(apiError.errorDescription, "DigitalOcean API error (HTTP 404): Not found")

        let invalidURL = DigitalOceanError.invalidURL
        XCTAssertEqual(invalidURL.errorDescription, "Invalid URL")
    }
}
