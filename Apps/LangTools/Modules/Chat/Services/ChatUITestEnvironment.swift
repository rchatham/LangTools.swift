//
//  ChatUITestEnvironment.swift
//  Chat
//
//  Debug-only, macOS-only validated fixture runtime that isolates UI test
//  state from personal credentials, accounts, and real network services.
//

import Foundation

// MARK: - Resolver error

/// Error thrown by the pure-policy resolver when a fail-closed condition is
/// encountered. The app runtime wrapper converts this to a `preconditionFailure`
/// so no personal state is ever touched.
public enum ChatUITestEnvironmentError: Error, CustomStringConvertible {
    /// The LANGTOOLS_UI_TEST_MODE env var was set on a non-fixture bundle.
    case wrongBundle
    /// The LANGTOOLS_UI_TEST_MODE env var was set to an unrecognized value
    /// on the fixture bundle.
    case unrecognizedMode

    public var description: String {
        switch self {
        case .wrongBundle:
            return "LANGTOOLS_UI_TEST_MODE is set on a non-fixture bundle — personal state must never be exposed."
        case .unrecognizedMode:
            return "Unrecognized LANGTOOLS_UI_TEST_MODE value on the fixture bundle — failing closed."
        }
    }
}

// MARK: - Environment

/// Sanitized UI test environment with fail-closed validation.
///
/// All recognized modes (`codexSuccess`, `codexNotLoggedIn`, `standard`) require
/// the dedicated fixture bundle `com.reidchatham.LangTools-Example-UIFixture`.
/// Any LANGTOOLS_UI_TEST_MODE on a wrong bundle, or an unrecognized mode on the
/// fixture bundle, is a fail-closed error.
///
/// No env var → normal app run (`nil`).
/// Release / non-macOS → always `nil`.
public enum ChatUITestEnvironment: String, CaseIterable {
    case codexSuccess
    case codexNotLoggedIn
    case standard

    // MARK: - Runtime entry point (fatal on fail-closed)

    /// Validated fixture environment, or `nil` for a normal run.
    ///
    /// **Fatal error** on fail-closed conditions — personal state is never accessed.
    public static var current: ChatUITestEnvironment? {
        do {
            return try resolve()
        } catch {
            preconditionFailure("\(error)")
        }
    }

    /// `true` when a validated fixture environment is active.
    public static var isFixtureActive: Bool { current != nil }

    // MARK: - Pure injected resolver

    /// Pure-policy resolver. Accepts all inputs explicitly so unit tests can
    /// exercise every path deterministically without mutating global env or
    /// relying on the host bundle identity.
    ///
    /// - Parameters:
    ///   - rawMode: Value of `LANGTOOLS_UI_TEST_MODE` (nil when unset).
    ///   - bundleIdentifier: Host bundle identifier.
    ///   - isDebug: Whether compiled under `#if DEBUG`.
    ///   - isMacOS: Whether targeting `os(macOS)`.
    /// - Returns: Recognized mode, `nil` for normal run.
    /// - Throws: `wrongBundle` or `unrecognizedMode` on fail-closed conditions.
    public static func resolve(
        rawMode: String?,
        bundleIdentifier: String,
        isDebug: Bool,
        isMacOS: Bool
    ) throws -> ChatUITestEnvironment? {
        guard isDebug && isMacOS else {
            // Release builds and non-macOS targets never expose fixture behaviour.
            return nil
        }

        guard let rawMode else {
            // Normal app run — no env var set.
            return nil
        }

        // An env var is set. Bundle must be the fixture bundle.
        guard bundleIdentifier == fixtureBundleIdentifier else {
            throw ChatUITestEnvironmentError.wrongBundle
        }

        // Must be a recognized mode.
        guard let mode = ChatUITestEnvironment(rawValue: rawMode) else {
            throw ChatUITestEnvironmentError.unrecognizedMode
        }

        return mode
    }

    /// Production runtime resolver that reads the actual environment.
    static func resolve() throws -> ChatUITestEnvironment? {
        try resolve(
            rawMode: ProcessInfo.processInfo.environment["LANGTOOLS_UI_TEST_MODE"],
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            isDebug: _isDebug,
            isMacOS: _isMacOS
        )
    }

    /// Compile-time debug flag. Mirrors `#if DEBUG` so tests can pass `false`
    /// for the Release path.
    #if DEBUG
    private static let _isDebug = true
    #else
    private static let _isDebug = false
    #endif

    /// Compile-time OS flag.
    #if os(macOS)
    private static let _isMacOS = true
    #else
    private static let _isMacOS = false
    #endif

    // MARK: - Bundle identity

    /// The **only** bundle identifier that may activate the fixture environment.
    public static let fixtureBundleIdentifier = "com.reidchatham.LangTools-Example-UIFixture"

    // MARK: - Fixture isolation namespaces

    /// Keychain service name for the fixture — must not overlap with the
    /// ordinary app service (`com.reidchatham.LangTools_Example`).
    public static let fixtureKeychainService = "com.reidchatham.LangTools_Example-UIFixture"

    /// UserDefaults suite name for the fixture environment.
    public static let fixtureUserDefaultsSuite = "com.reidchatham.LangTools-Example-UIFixture"

    /// Returns the fixture-specific UserDefaults suite when the fixture is active.
    public static var isolatedUserDefaults: UserDefaults? {
        guard ChatUITestEnvironment.isFixtureActive else { return nil }
        return UserDefaults(suiteName: fixtureUserDefaultsSuite)
    }

    // MARK: - Service suppression

    /// When `true`, all real startup services must be suppressed.
    public static var suppressRealServices: Bool { isFixtureActive }
}