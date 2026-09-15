@testable import Chat
import Foundation
import KeychainAccess
import Testing
@testable import LangToolsApp

@Test func appIdentityPreservesExistingInstallations() {
    // A display/product rename must not orphan preferences or the app container.
    #expect(Bundle.main.bundleIdentifier == "com.reidchatham.LangTools-Example")
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "LangTools")
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "LangTools")
}

#if os(macOS)
@Test func signedHostCanAccessPreservedKeychainService() throws {
    // Requires a signed host; unsigned macOS runners lack keychain entitlements.
    // Exercise the real shared instance so a future initializer-default change
    // cannot silently move credentials away from the preserved namespace.
    #expect(KeychainService.shared.keychain.service == "com.reidchatham.LangTools_Example")

    let keychain = Keychain(service: KeychainService.serviceIdentifier)
    let account = "promotion-smoke-\(UUID().uuidString)"
    let value = UUID().uuidString

    defer { try? keychain.remove(account) }

    try keychain.set(value, key: account)
    #expect(try keychain.getString(account) == value)
    try keychain.remove(account)
    #expect(try keychain.getString(account) == nil)
}
#endif
