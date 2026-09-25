//
//  CodexHelperPairing.swift
//

import Foundation

/// The loopback helper endpoint described by a pairing URL.
public struct PairedHelper: Equatable {
    public let port: Int
    public let code: String

    public init(port: Int, code: String) {
        self.port = port
        self.code = code
    }
}

/// Strict validation failures for pairing URLs.
public enum PairingError: Error, Equatable {
    case malformedURL
    case invalidScheme
    case invalidHost
    case invalidPath
    case invalidPort
    case invalidCode
}

/// The result of a pairing-code exchange against the helper.
public struct PairingCodeExchangeResponse: Codable, Equatable {
    public let port: Int
    public let token: String
}

/// The outcome of confirming a pairing against the helper's `/health` endpoint.
public enum PairingOutcome: Equatable {
    case verified(port: Int)
    case verificationFailed(port: Int, message: String)
}

private enum PairingVerificationError: LocalizedError {
    case unexpectedHealthResponse

    var errorDescription: String? { "The Codex helper returned an unexpected health response." }
}

/// Summary pairing state for the Settings UI.
public enum PairingStatus: Equatable {
    case notPaired
    case paired(port: Int)
    case verified(port: Int)
    case verificationFailed(port: Int, message: String)
}

/// The pairing URL contract shared with the Codex helper app:
/// `langtools-example-auth://codex-helper/pair?port=<1-65535>&code=<64 hex>`.
public enum CodexHelperPairingContract {
    public static let scheme = "langtools-example-auth"
    public static let host = "codex-helper"
    public static let path = "/pair"
    static let defaultHelperPort = 8765
    private static let hexDigits: Set<Character> = Set("0123456789abcdefABCDEF")

    /// ASCII decimal digits only, at most five (range checked separately).
    static func isValidPortString(_ value: String) -> Bool {
        (1...5).contains(value.count) && value.allSatisfy { ("0"..."9").contains($0) }
    }

    /// Exactly 64 characters from `[0-9a-fA-F]`.
    static func isValidHexCode(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { hexDigits.contains($0) }
    }
}

/// Coordinates one-click pairing with the Codex helper app.
///
/// The helper opens a URL matching `CodexHelperPairingContract`. Incoming URLs
/// are validated strictly, presented to the user for confirmation, and only
/// persisted after the user taps Pair.
@MainActor
public final class CodexHelperPairingCoordinator: ObservableObject {
    public static let shared = CodexHelperPairingCoordinator()

    @Published public private(set) var pendingPairing: PairedHelper?
    @Published public private(set) var pairedHelper: PairedHelper?
    @Published public private(set) var lastPairingResult: PairingOutcome?

    private let makeHelperClient: (AccountBackendConfiguration) -> CodexHelperClientProtocol
    private let saveToken: (String) throws -> Void
    private let exchangeCode: (String, Int) async throws -> PairingCodeExchangeResponse
    private var verificationID: UUID?
    private var verifiedTokenFingerprint: String?

    public convenience init(
        makeHelperClient: @escaping (AccountBackendConfiguration) -> CodexHelperClientProtocol = { CodexHelperClient(configuration: $0) },
        saveToken: @escaping (String) throws -> Void = { try CodexHelperTokenStore().setToken($0) }
    ) {
        self.init(
            makeHelperClient: makeHelperClient,
            saveToken: saveToken,
            exchangeCode: Self.performExchange
        )
    }

    public init(
        makeHelperClient: @escaping (AccountBackendConfiguration) -> CodexHelperClientProtocol,
        saveToken: @escaping (String) throws -> Void,
        exchangeCode: @escaping (String, Int) async throws -> PairingCodeExchangeResponse
    ) {
        self.makeHelperClient = makeHelperClient
        self.saveToken = saveToken
        self.exchangeCode = exchangeCode
    }

    /// Exchanges a short-lived pairing code for the long-lived helper token
    /// over loopback HTTP (no bearer authorization). On any non-200 response
    /// the helper's error message is surfaced.
    nonisolated static func performExchange(code: String, port: Int) async throws -> PairingCodeExchangeResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/pairing/exchange")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(HelperErrorPayload.self, from: data).error) ?? "The Codex helper rejected the pairing code."
            throw AccountLoginError.sessionExchangeFailed(message)
        }
        return try JSONDecoder().decode(PairingCodeExchangeResponse.self, from: data)
    }

    // MARK: - URL parsing

    /// Validates a pairing URL against the pairing contract: scheme
    /// `langtools-example-auth` (case-insensitive), host `codex-helper`
    /// (case-insensitive), path `/pair`, `port` in `1...65535`, and a `code`
    /// matching `^[0-9a-fA-F]{64}$`. Pure — performs no I/O.
    nonisolated public static func parsePairingURL(_ url: URL) -> Result<PairedHelper, PairingError> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.malformedURL)
        }

        guard components.scheme?.lowercased() == CodexHelperPairingContract.scheme else {
            return .failure(.invalidScheme)
        }

        guard components.host?.lowercased() == CodexHelperPairingContract.host else {
            return .failure(.invalidHost)
        }

        guard components.path == CodexHelperPairingContract.path,
              components.user == nil, components.password == nil, components.fragment == nil else {
            return .failure(.invalidPath)
        }

        let queryItems = components.queryItems ?? []

        guard let portString = queryItems.first(where: { $0.name == "port" })?.value,
              CodexHelperPairingContract.isValidPortString(portString),
              let port = Int(portString),
              (1...65535).contains(port)
        else {
            return .failure(.invalidPort)
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value,
              CodexHelperPairingContract.isValidHexCode(code)
        else {
            return .failure(.invalidCode)
        }
        guard queryItems.count == 2 else { return .failure(.malformedURL) }

        return .success(PairedHelper(port: port, code: code))
    }

    /// Whether `url` is addressed to the pairing flow (`codex-helper` host,
    /// case-insensitive). Used to route incoming custom-scheme URLs.
    nonisolated public static func isPairingURL(_ url: URL) -> Bool {
        url.host?.lowercased() == CodexHelperPairingContract.host
    }

    // MARK: - Pairing flow

    /// Handles an incoming URL. Valid pairing URLs become the pending pairing
    /// awaiting user confirmation; anything else is ignored silently.
    public func handle(_ url: URL) {
        guard Self.isPairingURL(url) else {
            return
        }

        switch Self.parsePairingURL(url) {
        case .success(let helper):
            guard pendingPairing == nil else { return }
            pendingPairing = helper
        case .failure:
            break
        }
    }

    /// Exchanges the short-lived pairing code for the long-lived token, then
    /// verifies the helper and saves the verified token and URL. SwiftUI may
    /// dismiss the alert before invoking its button action, so confirmation
    /// uses the captured payload, not pending state.
    public func confirm(_ pairing: PairedHelper) {
        pendingPairing = nil
        lastPairingResult = nil
        let id = UUID()
        verificationID = id

        Task {
            do {
                let exchange = try await exchangeCode(pairing.code, pairing.port)
                guard verificationID == id else { return }

                let baseURL = URL(string: "http://127.0.0.1:\(pairing.port)")!
                let configuration = AccountBackendConfiguration(
                    codexHelperBaseURL: baseURL,
                    codexHelperToken: exchange.token
                )
                let health = try await makeHelperClient(configuration).healthCheck()
                guard health.status == "ok", health.version == 1 else {
                    throw PairingVerificationError.unexpectedHealthResponse
                }
                guard verificationID == id else { return }
                try saveToken(exchange.token)
                UserDefaults.codexHelperBaseURL = baseURL
                pairedHelper = PairedHelper(port: exchange.port, code: "")
                verifiedTokenFingerprint = exchange.token
                lastPairingResult = .verified(port: exchange.port)
            } catch {
                guard verificationID == id else { return }
                lastPairingResult = .verificationFailed(port: pairing.port, message: error.localizedDescription)
            }
        }
    }

    /// Discards the pending pairing without saving anything.
    public func cancel() {
        pendingPairing = nil
    }

    /// Clears a transient pairing result (e.g. after the user dismisses the
    /// failure alert) so Settings falls back to the persisted state.
    public func dismissResult() {
        lastPairingResult = nil
    }

    /// Current pairing state for Settings UI display. Falls back to the
    /// persisted token/URL when no pairing has been confirmed this session.
    /// A verified result is downgraded to `.paired` if the persisted token
    /// no longer matches the value that was verified (e.g. after a manual edit).
    public var pairingStatus: PairingStatus {
        if let result = lastPairingResult {
            switch result {
            case .verified(let port):
                let persisted = UserDefaults.codexHelperToken
                if verifiedTokenFingerprint == persisted, persisted.isEmpty == false {
                    return .verified(port: port)
                }
                return .paired(port: port)
            case .verificationFailed(let port, let message):
                return .verificationFailed(port: port, message: message)
            }
        }

        guard UserDefaults.codexHelperToken.isEmpty == false else {
            return .notPaired
        }

        return .paired(port: UserDefaults.codexHelperBaseURL.port ?? CodexHelperPairingContract.defaultHelperPort)
    }
}