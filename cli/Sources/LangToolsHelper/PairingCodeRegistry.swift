import Foundation
#if canImport(Security)
import Security
#endif

/// Single-use pairing-code registry with TTL.
///
/// Codes are high-entropy 64-hex nonces; the probabilistic expiry combined
/// with single-use consumption makes hash-keyed lookup acceptable for the
/// local-development threat model. No constant-time guarantee is made.
actor PairingCodeRegistry {
    typealias EntropyProvider = @Sendable (inout [UInt8]) -> Bool

    private var pending: [String: ContinuousClock.Instant] = [:]
    private let ttl: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let fillEntropy: EntropyProvider

    init(
        ttl: Duration = .seconds(300),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        fillEntropy: @escaping EntropyProvider = { bytes in
            PairingCodeRegistry.fillSecureRandomBytes(&bytes)
        }
    ) {
        self.ttl = ttl
        self.now = now
        self.fillEntropy = fillEntropy
    }

    /// Generates a fresh 64-hex code and returns it.
    func generate() throws -> String {
        prune()
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = fillEntropy(&bytes)
        guard status else { throw PairingCodeRegistryError.entropyGenerationFailed }
        let code = bytes.map { String(format: "%02x", $0) }.joined()
        pending[code] = now()
        return code
    }

    /// Consumes (removes) a valid, unexpired code; returns `true` on success.
    func consume(_ code: String) -> Bool {
        prune()
        guard let createdAt = pending.removeValue(forKey: code) else { return false }
        return createdAt.advanced(by: ttl) >= now()
    }

    /// Internal visibility supports deterministic pruning assertions without
    /// exposing registry state outside the helper module.
    var pendingCodeCount: Int { pending.count }

    private func prune() {
        let currentInstant = now()
        pending = pending.filter { $0.value.advanced(by: ttl) >= currentInstant }
    }

    private static func fillSecureRandomBytes(_ bytes: inout [UInt8]) -> Bool {
        #if canImport(Security)
        return SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        #else
        guard let handle = FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/urandom")) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes.count), data.count == bytes.count else {
            return false
        }
        bytes = [UInt8](data)
        return true
        #endif
    }
}

enum PairingCodeRegistryError: Error {
    case entropyGenerationFailed
}
