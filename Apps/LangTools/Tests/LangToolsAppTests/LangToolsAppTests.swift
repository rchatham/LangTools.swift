@testable import Chat
import Foundation
import KeychainAccess
import Testing
import XCTest
@testable import LangToolsApp

@Test func appIdentityPreservesExistingInstallations() {
    // A display/product rename must not orphan preferences or the app container.
    #expect(Bundle.main.bundleIdentifier == "com.reidchatham.LangTools-Example")
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "LangTools")
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "LangTools")
    #expect(KeychainService.shared.keychain.service == "com.reidchatham.LangTools_Example")
}

#if os(macOS)
final class KeychainHostSmokeTests: XCTestCase {
    func testSignedHostCanAccessPreservedKeychainService() throws {
        // Requires a signed host; unsigned macOS runners lack keychain entitlements.
        // Exercise the real shared instance so a future initializer-default change
        // cannot silently move credentials away from the preserved namespace.
        XCTAssertEqual(KeychainService.shared.keychain.service, "com.reidchatham.LangTools_Example")

        let keychain = Keychain(service: KeychainService.shared.keychain.service)
        let account = "promotion-smoke-\(UUID().uuidString)"
        let value = UUID().uuidString

        // Remove stale smoke accounts left by interrupted earlier runs.
        for staleAccount in keychain.allKeys() where staleAccount.hasPrefix("promotion-smoke-") {
            try? keychain.remove(staleAccount)
        }

        defer { try? keychain.remove(account) }

        do {
            try keychain.set(value, key: account)
        } catch let status as KeychainAccess.Status where status == .missingEntitlement {
            throw XCTSkip("Keychain entitlements unavailable on this (likely unsigned) host")
        }
        XCTAssertEqual(try keychain.getString(account), value)
        try keychain.remove(account)
        XCTAssertNil(try keychain.getString(account))
    }
}
#endif
