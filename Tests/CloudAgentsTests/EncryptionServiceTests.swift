//
//  EncryptionServiceTests.swift
//  LangTools
//
//  Created by Claude on 2025.
//

import XCTest
@testable import CloudAgents

final class EncryptionServiceTests: XCTestCase {
    var encryptionService: NotificationEncryptionService!

    override func setUp() {
        super.setUp()
        encryptionService = NotificationEncryptionService()
    }

    override func tearDown() {
        encryptionService = nil
        super.tearDown()
    }

    func testGenerateEncryptionKey() {
        let key = encryptionService.generateEncryptionKey()
        XCTAssertFalse(key.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: key))

        // Key should be 32 bytes (256 bits) base64 encoded
        if let keyData = Data(base64Encoded: key) {
            XCTAssertEqual(keyData.count, 32)
        }
    }

    func testGenerateUniqueKeys() {
        let key1 = encryptionService.generateEncryptionKey()
        let key2 = encryptionService.generateEncryptionKey()
        XCTAssertNotEqual(key1, key2)
    }

    func testGenerateNonce() {
        let nonce = encryptionService.generateNonce()
        XCTAssertFalse(nonce.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: nonce))

        // Nonce should be 12 bytes base64 encoded
        if let nonceData = Data(base64Encoded: nonce) {
            XCTAssertEqual(nonceData.count, 12)
        }
    }

    #if canImport(CryptoKit)
    func testEncryptDecryptRoundTrip() throws {
        let key = encryptionService.generateEncryptionKey()

        let result = AgentExecutionResult(
            status: .completed,
            output: "Test output from agent",
            error: nil,
            executionTime: 120.0,
            resourceUsage: nil
        )

        let notification = AgentNotification(
            agentName: "test-agent",
            result: result,
            timestamp: Date()
        )

        // Encrypt
        let encrypted = try encryptionService.encrypt(
            notification: notification,
            userKey: key
        )

        XCTAssertFalse(encrypted.data.isEmpty)
        XCTAssertFalse(encrypted.nonce.isEmpty)
        XCTAssertEqual(encrypted.agentId, "test-agent")

        // Decrypt
        let decrypted = try encryptionService.decrypt(
            payload: encrypted,
            userKey: key
        )

        XCTAssertEqual(decrypted.agentName, notification.agentName)
        XCTAssertEqual(decrypted.result.status, notification.result.status)
        XCTAssertEqual(decrypted.result.output, notification.result.output)
        XCTAssertEqual(decrypted.result.executionTime, notification.result.executionTime)
    }

    func testEncryptDecryptWithResourceUsage() throws {
        let key = encryptionService.generateEncryptionKey()

        let resourceUsage = ResourceUsage(
            cpuUsage: 45.5,
            memoryUsage: 512_000_000,
            networkUsage: ResourceUsage.NetworkUsage(bytesIn: 1024, bytesOut: 2048)
        )

        let result = AgentExecutionResult(
            status: .completed,
            output: "Completed with resources",
            error: nil,
            executionTime: 300.0,
            resourceUsage: resourceUsage
        )

        let notification = AgentNotification(
            agentName: "resource-test-agent",
            result: result
        )

        let encrypted = try encryptionService.encrypt(notification: notification, userKey: key)
        let decrypted = try encryptionService.decrypt(payload: encrypted, userKey: key)

        XCTAssertEqual(decrypted.result.resourceUsage?.cpuUsage, 45.5)
        XCTAssertEqual(decrypted.result.resourceUsage?.memoryUsage, 512_000_000)
        XCTAssertEqual(decrypted.result.resourceUsage?.networkUsage.bytesIn, 1024)
        XCTAssertEqual(decrypted.result.resourceUsage?.networkUsage.bytesOut, 2048)
    }

    func testDecryptWithWrongKeyFails() throws {
        let key1 = encryptionService.generateEncryptionKey()
        let key2 = encryptionService.generateEncryptionKey()

        let notification = AgentNotification(
            agentName: "test-agent",
            result: AgentExecutionResult(
                status: .completed,
                output: "Test",
                error: nil,
                executionTime: 1.0,
                resourceUsage: nil
            )
        )

        let encrypted = try encryptionService.encrypt(
            notification: notification,
            userKey: key1
        )

        XCTAssertThrowsError(
            try encryptionService.decrypt(payload: encrypted, userKey: key2)
        )
    }

    func testEncryptWithInvalidKeyFails() {
        let notification = AgentNotification(
            agentName: "test-agent",
            result: AgentExecutionResult(
                status: .completed,
                output: "Test",
                error: nil,
                executionTime: 1.0,
                resourceUsage: nil
            )
        )

        XCTAssertThrowsError(
            try encryptionService.encrypt(notification: notification, userKey: "invalid-key")
        )
    }

    func testDecryptWithInvalidPayloadFails() {
        let key = encryptionService.generateEncryptionKey()

        let invalidPayload = EncryptedNotificationPayload(
            data: "invalid-data",
            nonce: "invalid-nonce",
            agentId: "test"
        )

        XCTAssertThrowsError(
            try encryptionService.decrypt(payload: invalidPayload, userKey: key)
        )
    }

    func testEncryptedPayloadFormat() throws {
        let key = encryptionService.generateEncryptionKey()

        let notification = AgentNotification(
            agentName: "format-test",
            result: AgentExecutionResult(
                status: .completed,
                output: "Test",
                error: nil,
                executionTime: 1.0,
                resourceUsage: nil
            )
        )

        let encrypted = try encryptionService.encrypt(notification: notification, userKey: key)

        // Data should be in format "ciphertext.tag"
        let components = encrypted.data.split(separator: ".")
        XCTAssertEqual(components.count, 2)

        // Both components should be valid base64
        XCTAssertNotNil(Data(base64Encoded: String(components[0])))
        XCTAssertNotNil(Data(base64Encoded: String(components[1])))
    }
    #endif
}
