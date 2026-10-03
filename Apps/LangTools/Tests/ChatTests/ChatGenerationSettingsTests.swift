import Dispatch
import Foundation
import XCTest
@testable import Chat

final class ChatGenerationSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ChatGenerationSettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "ChatGenerationSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = ChatGenerationSettingsStore(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAutomaticAndExplicitZeroRoundTrip() throws {
        store.save(.automatic)
        XCTAssertEqual(store.load(), .automatic)

        let explicitZero = try ChatGenerationSettings(temperature: 0)
        store.save(explicitZero)
        XCTAssertEqual(store.load(), explicitZero)
        XCTAssertEqual(store.load().temperature, 0)
    }

    func testValidRepresentativeValues() throws {
        XCTAssertNoThrow(try ChatGenerationSettings(maxOutputTokens: 1, temperature: 0))
        XCTAssertNoThrow(try ChatGenerationSettings(maxOutputTokens: 16_384, temperature: 1))
    }

    func testRejectsInvalidTokens() {
        for value in [0, -1, Int.max] {
            XCTAssertThrowsError(try ChatGenerationSettings(maxOutputTokens: value))
        }
    }

    func testRejectsInvalidTemperatures() {
        for value in [-0.01, 1.01, .nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try ChatGenerationSettings(temperature: value))
        }
    }

    func testMigratesPositiveLegacyValuesAndLeavesKeys() throws {
        defaults.set(2_048, forKey: "max_tokens")
        defaults.set(0.65, forKey: "temperature")

        XCTAssertEqual(store.load(), try ChatGenerationSettings(maxOutputTokens: 2_048, temperature: 0.65))
        XCTAssertEqual(defaults.integer(forKey: "max_tokens"), 2_048)
        XCTAssertEqual(defaults.double(forKey: "temperature"), 0.65)
    }

    func testMissingAndLegacyZeroTemperatureBecomeAutomatic() throws {
        defaults.set(1_024, forKey: "max_tokens")
        XCTAssertEqual(store.load(), try ChatGenerationSettings(maxOutputTokens: 1_024))

        defaults.removeObject(forKey: "chat_generation_settings")
        defaults.set(0, forKey: "chat_generation_settings_migration_version")
        defaults.set(0.0, forKey: "temperature")
        XCTAssertEqual(store.load(), try ChatGenerationSettings(maxOutputTokens: 1_024))
    }

    func testMigrationPreservesIndependentlyValidField() throws {
        defaults.set("40000", forKey: "max_tokens")
        defaults.set(0.4, forKey: "temperature")
        XCTAssertEqual(store.load(), try ChatGenerationSettings(temperature: 0.4))
    }

    func testMigrationRejectsWrongTypesAndFractionalTokenCounts() {
        for invalidTokens in [true, "2048", 2_048.5] as [Any] {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(invalidTokens, forKey: "max_tokens")
            defaults.set(false, forKey: "temperature")

            XCTAssertEqual(store.load(), .automatic)
            XCTAssertEqual(defaults.integer(forKey: "chat_generation_settings_migration_version"), 1)
        }
    }

    func testWrongTypeMigrationMarkerDoesNotSuppressMigration() throws {
        defaults.set("1", forKey: "chat_generation_settings_migration_version")
        defaults.set(2_048, forKey: "max_tokens")

        XCTAssertEqual(store.load(), try ChatGenerationSettings(maxOutputTokens: 2_048))
    }

    func testCorruptAndInvalidNewPayloadFailClosedWithoutRewriting() {
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: "chat_generation_settings")
        defaults.set(2_048, forKey: "max_tokens")
        XCTAssertEqual(store.load(), .automatic)
        XCTAssertEqual(defaults.data(forKey: "chat_generation_settings"), corrupt)

        let invalid = Data(#"{"schemaVersion":1,"settings":{"maxOutputTokens":0}}"#.utf8)
        defaults.set(invalid, forKey: "chat_generation_settings")
        XCTAssertEqual(store.load(), .automatic)
        XCTAssertEqual(defaults.data(forKey: "chat_generation_settings"), invalid)
    }

    func testWrongTypeNewPayloadFailsClosedWithoutMigratingLegacyValues() {
        defaults.set("wrong-type", forKey: "chat_generation_settings")
        defaults.set(2_048, forKey: "max_tokens")
        XCTAssertEqual(store.load(), .automatic)
        XCTAssertEqual(defaults.string(forKey: "chat_generation_settings"), "wrong-type")
        XCTAssertEqual(defaults.integer(forKey: "chat_generation_settings_migration_version"), 0)
    }

    func testFutureSchemaFailsClosedWithoutRewriting() {
        let future = Data(#"{"schemaVersion":2,"settings":{}}"#.utf8)
        defaults.set(future, forKey: "chat_generation_settings")
        XCTAssertEqual(store.load(), .automatic)
        XCTAssertEqual(defaults.data(forKey: "chat_generation_settings"), future)
    }

    func testNewPayloadWinsWithoutMigrationMarker() throws {
        let expected = try ChatGenerationSettings(maxOutputTokens: 4_096, temperature: 0)
        store.save(expected)
        defaults.removeObject(forKey: "chat_generation_settings_migration_version")
        defaults.set(8_192, forKey: "max_tokens")
        defaults.set(0.8, forKey: "temperature")

        XCTAssertEqual(store.load(), expected)
        XCTAssertEqual(defaults.integer(forKey: "chat_generation_settings_migration_version"), 1)
    }

    func testLoadDoesNotRewriteCompletedMigrationMarker() throws {
        let expected = try ChatGenerationSettings(maxOutputTokens: 4_096)
        store.save(expected)
        defaults.set(2, forKey: "chat_generation_settings_migration_version")

        XCTAssertEqual(store.load(), expected)
        XCTAssertEqual(defaults.integer(forKey: "chat_generation_settings_migration_version"), 2)
    }

    func testCrossInstanceMigrationCannotOverwriteConcurrentSave() throws {
        defaults.set(1_024, forKey: "max_tokens")
        let migratingStore = ChatGenerationSettingsStore(userDefaults: defaults)
        let savingStore = ChatGenerationSettingsStore(userDefaults: defaults)
        let saved = try ChatGenerationSettings(maxOutputTokens: 8_192, temperature: 0.25)
        let migrationEntered = DispatchSemaphore(value: 0)
        let releaseMigration = DispatchSemaphore(value: 0)
        let migrationFinished = DispatchSemaphore(value: 0)
        let saveAttempted = DispatchSemaphore(value: 0)
        let saveEntered = DispatchSemaphore(value: 0)
        let saveFinished = DispatchSemaphore(value: 0)

        migratingStore.willPersist = { _ in
            migrationEntered.signal()
            releaseMigration.wait()
        }
        savingStore.willPersist = { _ in
            saveEntered.signal()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = migratingStore.load()
            migrationFinished.signal()
        }
        XCTAssertEqual(migrationEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            saveAttempted.signal()
            savingStore.save(saved)
            saveFinished.signal()
        }
        XCTAssertEqual(saveAttempted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(saveEntered.wait(timeout: .now() + 0.1), .timedOut)

        releaseMigration.signal()
        XCTAssertEqual(migrationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(saveEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(saveFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(store.load(), saved)
    }

    func testMigrationRunsOnceAndDoesNotOverwriteLaterSave() throws {
        defaults.set(1_024, forKey: "max_tokens")
        XCTAssertEqual(store.load(), try ChatGenerationSettings(maxOutputTokens: 1_024))
        let saved = try ChatGenerationSettings(maxOutputTokens: 8_192, temperature: 0.25)
        store.save(saved)
        defaults.set(32_768, forKey: "max_tokens")
        XCTAssertEqual(store.load(), saved)
    }

    func testResetPersistsAutomaticAndPreventsLegacyRemigration() {
        defaults.set(2_048, forKey: "max_tokens")
        defaults.set(0.5, forKey: "temperature")
        store.reset()

        XCTAssertEqual(store.load(), .automatic)
        XCTAssertNotNil(defaults.data(forKey: "chat_generation_settings"))
        XCTAssertEqual(defaults.integer(forKey: "chat_generation_settings_migration_version"), 1)
        XCTAssertEqual(defaults.integer(forKey: "max_tokens"), 2_048)
        XCTAssertEqual(defaults.double(forKey: "temperature"), 0.5)
    }

    func testDeprecatedUserDefaultsPropertiesPreserveLegacySemantics() {
        let standard = UserDefaults.standard
        let originalMaxTokens = standard.object(forKey: "max_tokens")
        let originalTemperature = standard.object(forKey: "temperature")
        defer {
            standard.set(originalMaxTokens, forKey: "max_tokens")
            standard.set(originalTemperature, forKey: "temperature")
        }

        standard.removeObject(forKey: "max_tokens")
        standard.removeObject(forKey: "temperature")
        XCTAssertEqual(UserDefaults.maxTokens, 0)
        XCTAssertEqual(UserDefaults.temperature, 0)

        UserDefaults.maxTokens = -42
        UserDefaults.temperature = 1.25
        XCTAssertEqual(UserDefaults.maxTokens, -42)
        XCTAssertEqual(UserDefaults.temperature, 1.25)
    }
}
