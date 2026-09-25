#if canImport(Darwin)
import Darwin
#endif
import Foundation
import HelperCore
#if canImport(Security)
import Security
#endif

/// Owns the shared helper token file at `~/.langtools/helper-token`, the
/// single source of truth for both the CLI `serve` command and the menu-bar
/// helper app.
///
/// When the file is missing the controller generates a fresh 64-hex token
/// (32 bytes of `SecRandomCopyBytes` entropy) and writes it owner-only: mode
/// 0600, `O_EXCL` creation, umask 077, and no trailing newline. An existing
/// file is validated with the `HelperTokenLoader` rules and reused as-is.
struct TokenFileController {
    enum TokenFileControllerError: LocalizedError, Sendable {
        case entropyGenerationFailed
        case createFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .entropyGenerationFailed:
                return "Unable to generate secure random bytes for the helper token."
            case .createFailed(let path):
                return "Unable to create the helper token file at \(path)."
            case .writeFailed(let path):
                return "Unable to write the helper token file at \(path)."
            }
        }
    }

    static let defaultTokenFileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".langtools/helper-token")

    /// 32 random bytes encode to 64 hex characters, the shape the pairing
    /// contract requires.
    static let tokenByteCount = 32

    let tokenFileURL: URL

    init(tokenFileURL: URL = TokenFileController.defaultTokenFileURL) {
        self.tokenFileURL = tokenFileURL
    }

    /// Returns a valid helper token: an existing token file is validated with
    /// the `HelperTokenLoader` rules and, if it matches the 64-hex pairing
    /// contract, reused; a legacy or malformed token is rotated. A missing
    /// file is generated and written.
    func ensureToken() throws -> String {
        if FileManager.default.fileExists(atPath: tokenFileURL.path) {
            let existing = try HelperTokenLoader.load(from: tokenFileURL.path)
            if Self.isPairingCompatible(existing) {
                return existing
            }
            // A legacy token that the loader accepts but one-click pairing
            // rejects (pairing requires exactly 64 hex). Rotate it so the
            // stored token always satisfies the pairing contract.
            FileHandle.standardError.write(Data("langtools: rotating legacy helper token to 64-hex format\n".utf8))
            try FileManager.default.removeItem(at: tokenFileURL)
            return try ensureToken()
        }
        let token = try Self.generateToken()
        do {
            try Self.createTokenFile(token: token, at: tokenFileURL)
        } catch TokenFileControllerError.createFailed where errno == EEXIST {
            // Another instance may have created the file after our existence
            // check. Read and validate its value rather than using ours.
            return try HelperTokenLoader.load(from: tokenFileURL.path)
        }
        return try HelperTokenLoader.load(from: tokenFileURL.path)
    }

    /// Whether a token matches the 64-hex shape required by one-click pairing.
    static func isPairingCompatible(_ token: String) -> Bool {
        let hexDigits = Set("0123456789abcdefABCDEF")
        return token.count == 64 && token.allSatisfy(hexDigits.contains)
    }

    /// Generates a fresh 64-hex token from secure random bytes.
    static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        let status = fillSecureRandomBytes(&bytes)
        guard status else { throw TokenFileControllerError.entropyGenerationFailed }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the token with owner-only permissions: umask 077 around the
    /// create, an owner-only parent directory, and `O_EXCL` so a file or
    /// symlink that appears between the existence check and the create fails
    /// closed instead of being followed or truncated. No trailing newline.
    private static func createTokenFile(token: String, at url: URL) throws {
        let savedUmask = umask(0o077)
        defer { umask(savedUmask) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )

        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TokenFileControllerError.createFailed(url.path) }
        var closed = false
        var complete = false
        defer {
            if closed == false { _ = close(descriptor) }
            // We exclusively created this path; a failed write must not leave
            // an invalid token that prevents every subsequent launch.
            if complete == false { _ = unlink(url.path) }
        }

        let data = Data(token.utf8)
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                #if canImport(Darwin)
                let written = Darwin.write(descriptor, base + offset, data.count - offset)
                #else
                let written = Glibc.write(descriptor, base + offset, data.count - offset)
                #endif
                if written < 0 {
                    if errno == EINTR { continue }
                    throw TokenFileControllerError.writeFailed(url.path)
                }
                guard written > 0 else { throw TokenFileControllerError.writeFailed(url.path) }
                offset += written
            }
        }
        let closeResult = close(descriptor)
        closed = true
        guard closeResult == 0 else { throw TokenFileControllerError.writeFailed(url.path) }
        complete = true
    }

    private static func fillSecureRandomBytes(_ bytes: inout [UInt8]) -> Bool {
        #if canImport(Security)
        SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        #else
        // Fallback for platforms without the Security framework: read the
        // same byte count from the operating system entropy pool.
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