import CryptoKit
import Foundation
import HelperLink
import KeychainAccess
import LangTools
import Security

public enum MobileHelperError: LocalizedError, Equatable {
    case invalidIdentity
    case disconnected
    case revoked
    case trustChanged
    case redirectRejected
    case unavailable
    case ollamaUnavailable
    case accountUnavailable
    case accountSignInRequired
    case missingCapability(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "The helper identity or granted capabilities did not match the pairing QR. Pair again from the Mac."
        case .disconnected: return "Helper disconnected. Scan a new QR on your Mac, or explicitly choose another transport in settings."
        case .revoked: return "This phone's helper access was revoked or expired. Scan a new pairing QR on the Mac."
        case .trustChanged: return "The helper certificate changed or is invalid. Do not bypass trust; scan a new QR on the trusted Mac."
        case .redirectRejected: return "The helper redirected a request. Redirects are blocked to protect your device credential. Pair again with the correct helper."
        case .unavailable: return "Cannot reach the paired Mac. Start LangToolsHelper, enable Connect iPhone, and join the same network. If its LAN address changed, scan a new QR."
        case .ollamaUnavailable: return "The helper is reachable but Ollama is unavailable. Start Ollama on the paired Mac and retry."
        case .accountUnavailable: return "The paired Mac's account service is unavailable. Sign in on the Mac and verify that its helper capability is enabled."
        case .accountSignInRequired: return MobileHelperAccountError.signInRequiredMessage
        case .missingCapability(let capability): return "This pairing does not grant \(capability) access. Enable it on the Mac and scan a new QR."
        case .persistence(let message): return "Helper credential could not be read or saved in Keychain. \(message)"
        }
    }

    public static func actionable(_ error: Error, session: URLSession? = nil) -> Error {
        if error is MobileHelperError { return error }
        if let urlError = error as? URLError {
            // Foundation reports cancelAuthenticationChallenge as -999 on macOS.
            // Distinguish a recorded pin rejection from ordinary task cancellation.
            if urlError.code == .cancelled,
               (session?.delegate as? MobileHelperSessionDelegate)?.hasRejectedTrust == true {
                return MobileHelperError.trustChanged
            }
            switch urlError.code {
            case .cancelled: return error
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .secureConnectionFailed: return MobileHelperError.trustChanged
            case .httpTooManyRedirects: return MobileHelperError.redirectRejected
            default: return MobileHelperError.unavailable
            }
        }
        if case LangToolsError.responseUnsuccessful(let status, _) = error {
            if status == 401 || status == 403 { return MobileHelperError.revoked }
            if (300..<400).contains(status) { return MobileHelperError.redirectRejected }
            if status == 502 || status == 503 || status == 504 { return MobileHelperError.ollamaUnavailable }
        }
        return error
    }
}

/// Only stored in Keychain. Never persist the pairing code/URL or log this record.
struct MobileHelperCredential: Codable, Equatable, Sendable, CustomStringConvertible {
    let endpoint: URL
    let helperID: String
    let fingerprint: String
    let name: String
    let deviceID: String
    let token: String
    let capabilities: [String]
    var description: String { "MobileHelperCredential(\(helperID), credential redacted)" }

    func validate() throws {
        // Reuse the strict wire validation for endpoint, UUID, pin and display text.
        let payload = MobileHelperPairingPayload(version: 1, endpoint: endpoint, helperID: helperID,
            fingerprint: fingerprint, code: String(repeating: "0", count: 64), name: name)
        _ = try MobileHelperPairingPayload.parse(payload.pairingURL())
        guard UUID(uuidString: deviceID) != nil, Self.isSecret(token), MobileHelperCapabilities.isValid(capabilities) else {
            throw MobileHelperError.invalidIdentity
        }
    }

    static func isSecret(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

protocol MobileHelperCredentialStoring: Sendable {
    func load(helperID: String) throws -> MobileHelperCredential?
    func save(_ credential: MobileHelperCredential) throws
    func remove(helperID: String) throws
}

final class MobileHelperCredentialStore: MobileHelperCredentialStoring, @unchecked Sendable {
    static let shared = MobileHelperCredentialStore()
    private let keychain: Keychain
    init(keychain: Keychain = Keychain(service: "LangTools.mobile-helper.devices")
        .accessibility(.afterFirstUnlockThisDeviceOnly)) { self.keychain = keychain }

    func load(helperID: String) throws -> MobileHelperCredential? {
        guard let data = try keychain.getData(helperID) else { return nil }
        let credential = try JSONDecoder().decode(MobileHelperCredential.self, from: data)
        try credential.validate()
        guard credential.helperID == helperID else { throw MobileHelperError.invalidIdentity }
        return credential
    }
    func save(_ credential: MobileHelperCredential) throws {
        try credential.validate()
        try keychain.set(JSONEncoder().encode(credential), key: credential.helperID)
    }
    func remove(helperID: String) throws { try keychain.remove(helperID) }
}

/// Deliberate identity-vs-address policy: the QR pins the exact leaf DER hash.
/// Basic X509 validates time/signature/chain anchored ONLY in that leaf. No DNS
/// hostname policy: a Mac's private LAN IP can change without changing identity.
/// No trust exception is installed globally; every session has its own immutable pin.
final class MobileHelperSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let fingerprint: String
    let origin: URL
    private let rejectionLock = NSLock()
    private var rejectedTrust = false
    var hasRejectedTrust: Bool {
        rejectionLock.lock(); defer { rejectionLock.unlock() }; return rejectedTrust
    }
    init(fingerprint: String, origin: URL) { self.fingerprint = fingerprint; self.origin = origin }

    static func validate(trust: SecTrust, fingerprint: String) -> Bool {
        guard let leaf = SecTrustGetCertificateAtIndex(trust, 0) else { return false }
        let data = SecCertificateCopyData(leaf) as Data
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == fingerprint,
              SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == origin.host,
              challenge.protectionSpace.port == (origin.port ?? 443),
              let trust = challenge.protectionSpace.serverTrust,
              Self.validate(trust: trust, fingerprint: fingerprint) else {
            rejectionLock.lock(); rejectedTrust = true; rejectionLock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        // Even same-origin redirects are forbidden. Return the original 3xx,
        // never a redirected request containing Authorization.
        completionHandler(nil)
    }

    static func session(endpoint: URL, fingerprint: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration,
            delegate: MobileHelperSessionDelegate(fingerprint: fingerprint, origin: endpoint), delegateQueue: nil)
    }
}

/// Snapshot owns credentials/session; changing settings never retargets an in-flight operation.
final class MobileHelperConnection: @unchecked Sendable {
    let credential: MobileHelperCredential
    let sessionLease: LangToolsSessionLease
    var session: URLSession { sessionLease.session }
    init(credential: MobileHelperCredential, session: URLSession? = nil) {
        self.credential = credential
        sessionLease = LangToolsSessionLease(session: session ?? MobileHelperSessionDelegate.session(
            endpoint: credential.endpoint, fingerprint: credential.fingerprint))
    }
    // Snapshots and captured providers share retirement ownership. An unselected
    // successful pairing retires here; selection changes never cancel consumers.
}
