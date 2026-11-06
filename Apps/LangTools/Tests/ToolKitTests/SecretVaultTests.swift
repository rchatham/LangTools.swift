//
//  SecretVaultTests.swift
//  ToolKitTests
//
//  Pins the Keychain access budget: presence checks never read secret data,
//  values are read at most once per process, and no-op writes are skipped.
//

import XCTest
@testable import ToolKit

final class SecretVaultTests: XCTestCase {
    private var backend: InMemorySecretVaultBackend!
    private var vault: SecretVault!

    override func setUp() {
        super.setUp()
        backend = InMemorySecretVaultBackend()
        vault = SecretVault(backend: backend)
    }

    func testAbsentSecretsNeverReadData() throws {
        XCTAssertFalse(vault.contains("openAI:apiKey"))
        XCTAssertNil(try vault.value(forKey: "openAI:apiKey"))
        XCTAssertNil(try vault.value(forKey: "anthropic:apiKey"))
        XCTAssertEqual(backend.readCount, 0)
        XCTAssertEqual(backend.inventoryCount, 1)
    }

    func testAllSecretsComeFromOneCachedRead() throws {
        try vault.setValue("sk-openai", forKey: "openAI:apiKey")
        try vault.setValue("sk-anthropic", forKey: "anthropic:apiKey")

        // A fresh process: nothing cached yet.
        let relaunched = SecretVault(backend: backend)
        let readsBefore = backend.readCount

        XCTAssertTrue(relaunched.contains("openAI:apiKey"))
        XCTAssertTrue(relaunched.contains("anthropic:apiKey"))
        XCTAssertFalse(relaunched.contains("xAI:apiKey"))
        XCTAssertEqual(backend.readCount, readsBefore, "Presence checks must not read secret data")

        for _ in 0..<10 {
            XCTAssertEqual(try relaunched.value(forKey: "openAI:apiKey"), "sk-openai")
            XCTAssertEqual(try relaunched.value(forKey: "anthropic:apiKey"), "sk-anthropic")
            XCTAssertNil(try relaunched.value(forKey: "xAI:apiKey"))
        }
        XCTAssertEqual(backend.readCount, readsBefore + 1)
        XCTAssertEqual(backend.inventoryCount, 2)
    }

    func testUnchangedWritesAreSkipped() throws {
        try vault.setValue("sk-openai", forKey: "openAI:apiKey")
        let writes = backend.writeCount
        try vault.setValue("sk-openai", forKey: "openAI:apiKey")
        XCTAssertEqual(backend.writeCount, writes)

        try vault.setValue("sk-rotated", forKey: "openAI:apiKey")
        XCTAssertEqual(backend.writeCount, writes + 1)
        XCTAssertEqual(try SecretVault(backend: backend).value(forKey: "openAI:apiKey"), "sk-rotated")
    }

    func testRemovingSecrets() throws {
        try vault.setValue("sk-openai", forKey: "openAI:apiKey")
        try vault.setValue("sk-anthropic", forKey: "anthropic:apiKey")

        try vault.removeValue(forKey: "openAI:apiKey")
        XCTAssertFalse(vault.contains("openAI:apiKey"))

        let relaunched = SecretVault(backend: backend)
        XCTAssertFalse(relaunched.contains("openAI:apiKey"))
        XCTAssertEqual(try relaunched.value(forKey: "anthropic:apiKey"), "sk-anthropic")

        try relaunched.removeValue(forKey: "anthropic:apiKey")
        XCTAssertTrue(backend.inventory().isEmpty, "An empty vault leaves no Keychain item behind")
    }

    func testRemovingAnAbsentSecretTouchesNothing() throws {
        try vault.removeValue(forKey: "openAI:apiKey")
        XCTAssertEqual(backend.readCount, 0)
        XCTAssertEqual(backend.writeCount, 0)
    }

    func testLegacyItemMigratesOnFirstUse() throws {
        backend.seedLegacy("sk-legacy", account: "openAI:apiKey")
        backend.seedLegacy("legacy-session", account: "openAI:accountSession")

        XCTAssertTrue(vault.contains("openAI:apiKey"))
        XCTAssertEqual(backend.readCount, 0)

        XCTAssertEqual(try vault.value(forKey: "openAI:apiKey"), "sk-legacy")
        XCTAssertEqual(try vault.value(forKey: "openAI:apiKey"), "sk-legacy")
        XCTAssertEqual(backend.readCount, 1, "Only the needed legacy item is read, once")

        let accounts = Set(backend.inventory().map(\.account))
        XCTAssertEqual(accounts, [SecretVault.vaultAccount, "openAI:accountSession"])

        let relaunched = SecretVault(backend: backend)
        XCTAssertEqual(try relaunched.value(forKey: "openAI:apiKey"), "sk-legacy")
        XCTAssertEqual(try relaunched.value(forKey: "openAI:accountSession"), "legacy-session")
        XCTAssertEqual(Set(backend.inventory().map(\.account)), [SecretVault.vaultAccount])
    }

    func testWritingOverALegacyItemReplacesIt() throws {
        backend.seedLegacy("sk-legacy", account: "openAI:apiKey")
        try vault.setValue("sk-new", forKey: "openAI:apiKey")

        XCTAssertEqual(Set(backend.inventory().map(\.account)), [SecretVault.vaultAccount])
        XCTAssertEqual(try SecretVault(backend: backend).value(forKey: "openAI:apiKey"), "sk-new")
    }

    func testRemovingALegacySecretDeletesIt() throws {
        backend.seedLegacy("sk-legacy", account: "openAI:apiKey")
        try vault.removeValue(forKey: "openAI:apiKey")

        XCTAssertTrue(backend.inventory().isEmpty)
        XCTAssertFalse(SecretVault(backend: backend).contains("openAI:apiKey"))
        XCTAssertEqual(backend.readCount, 0)
    }

    func testSharedVaultIsOnePerService() {
        let service = "SecretVaultTests.\(UUID().uuidString)"
        XCTAssertTrue(SecretVault.shared(service: service) === SecretVault.shared(service: service))
        XCTAssertFalse(SecretVault.shared(service: service) === SecretVault.shared(service: service + ".other"))
    }
}
