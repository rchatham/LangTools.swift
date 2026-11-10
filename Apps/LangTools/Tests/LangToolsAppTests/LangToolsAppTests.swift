@testable import Chat
import Foundation
import Security
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

#if os(macOS)
/// Exercises real Security.framework failures against a disposable Keychain only.
final class IsolatedKeychainAccessTests: XCTestCase {
    func testLockedKeychainDenialIsCachedUntilExplicitRetry() throws {
        let path = NSTemporaryDirectory() + "LangTools-Keychain-" + UUID().uuidString + ".keychain-db"
        let password = UUID().uuidString
        var keychain: SecKeychain?
        let created = password.withCString { bytes in
            SecKeychainCreate(path, UInt32(password.utf8.count), bytes, false, nil, &keychain)
        }
        XCTAssertEqual(created, errSecSuccess)
        guard created == errSecSuccess, let keychain else { return }
        defer { XCTAssertEqual(SecKeychainDelete(keychain), errSecSuccess) }

        var interactionAllowed: DarwinBoolean = true
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&interactionAllowed), errSecSuccess)
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(false), errSecSuccess)
        defer { SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue) }

        let service = "isolated-cache-verification"
        let account = "synthetic-account"
        let secret = "synthetic-secret"
        let added = service.withCString { serviceBytes in
            account.withCString { accountBytes in
                secret.withCString { secretBytes in
                    SecKeychainAddGenericPassword(keychain, UInt32(service.utf8.count), serviceBytes,
                        UInt32(account.utf8.count), accountBytes, UInt32(secret.utf8.count), secretBytes, nil)
                }
            }
        }
        XCTAssertEqual(added, errSecSuccess)
        guard added == errSecSuccess else { return }
        var reads = 0
        func read() throws -> String? {
            reads += 1
            var length: UInt32 = 0
            var bytes: UnsafeMutableRawPointer?
            let status = service.withCString { serviceBytes in
                account.withCString { accountBytes in
                    SecKeychainFindGenericPassword(keychain, UInt32(service.utf8.count), serviceBytes,
                        UInt32(account.utf8.count), accountBytes, &length, &bytes, nil)
                }
            }
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            defer { SecKeychainItemFreeContent(nil, bytes) }
            return bytes.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(length)), as: UTF8.self) }
        }
        let cache = CredentialReadCache<String>()
        XCTAssertEqual(try cache.read(account, load: read), secret)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(SecKeychainLock(keychain), errSecSuccess)
        var status: SecKeychainStatus = 0
        XCTAssertEqual(SecKeychainGetStatus(keychain, &status), errSecSuccess)
        XCTAssertEqual(status & UInt32(kSecUnlockStateStatus), 0)
        for _ in 0..<10 { XCTAssertEqual(try cache.read(account, load: read), secret) }
        XCTAssertEqual(reads, 1, "Warm cache must not access a locked Keychain")

        cache.invalidate()
        for _ in 0..<10 {
            XCTAssertThrowsError(try cache.read(account, load: read)) { error in
                XCTAssertTrue([Int(errSecInteractionNotAllowed), Int(errSecAuthFailed)].contains((error as NSError).code))
            }
        }
        XCTAssertEqual(reads, 2, "Denied access must not be retried by routine reads")
        let unlocked = password.withCString { SecKeychainUnlock(keychain, UInt32(password.utf8.count), $0, true) }
        XCTAssertEqual(unlocked, errSecSuccess)
        XCTAssertThrowsError(try cache.read(account, load: read))
        XCTAssertEqual(reads, 2, "Unlock alone must not trigger an implicit retry")
        cache.invalidate()
        XCTAssertEqual(try cache.read(account, load: read), secret)
        XCTAssertEqual(reads, 3)
    }
}
#endif
