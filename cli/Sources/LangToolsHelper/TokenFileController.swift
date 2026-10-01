#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
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
/// (32 bytes of `SecRandomCopyBytes` entropy), writes it to an owner-only
/// same-directory temporary file, and atomically publishes it without a
/// partially written target ever becoming visible. A sibling lock file
/// serializes cooperating helper processes. Existing token files are validated
/// with the `HelperTokenLoader` rules and reused as-is.
struct TokenFileController {
    private static let processLock = NSLock()

    enum TokenFileControllerError: LocalizedError, Sendable {
        case entropyGenerationFailed
        case lockFailed(path: String, errno: Int32)
        case createFailed(path: String, errno: Int32)
        case writeFailed(path: String, errno: Int32)
        case publishFailed(path: String, errno: Int32)
        case replaceFailed(path: String, errno: Int32)

        var errorDescription: String? {
            switch self {
            case .entropyGenerationFailed:
                return "Unable to generate secure random bytes for the helper token."
            case .lockFailed(let path, let errorCode):
                return "Unable to lock the helper token file at \(path) (POSIX error \(errorCode))."
            case .createFailed(let path, let errorCode):
                return "Unable to create the helper token file at \(path) (POSIX error \(errorCode))."
            case .writeFailed(let path, let errorCode):
                return "Unable to write the helper token file at \(path) (POSIX error \(errorCode))."
            case .publishFailed(let path, let errorCode):
                return "Unable to publish the helper token file at \(path) (POSIX error \(errorCode))."
            case .replaceFailed(let path, let errorCode):
                return "Unable to replace the helper token file at \(path) (POSIX error \(errorCode))."
            }
        }
    }

    static let defaultTokenFileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".langtools/helper-token")

    /// 32 random bytes encode to 64 hex characters, the shape the pairing
    /// contract requires.
    static let tokenByteCount = 32

    let tokenFileURL: URL

    private var lockFileURL: URL {
        URL(fileURLWithPath: tokenFileURL.path + ".lock")
    }

    init(tokenFileURL: URL = TokenFileController.defaultTokenFileURL) {
        self.tokenFileURL = tokenFileURL
    }

    /// Returns a valid helper token: an existing token file is validated with
    /// the `HelperTokenLoader` rules and, if it matches the 64-hex pairing
    /// contract, reused; a legacy or malformed token is rotated. A missing
    /// file is generated and written.
    func ensureToken() throws -> String {
        try Self.ensureParentDirectory(for: tokenFileURL)
        return try Self.withExclusiveLock(at: lockFileURL) {
            if FileManager.default.fileExists(atPath: tokenFileURL.path) {
                return try reuseOrRotateExistingToken()
            }

            let token = try Self.generateToken()
            do {
                try Self.publish(token: token, at: tokenFileURL)
            } catch TokenFileControllerError.publishFailed(_, let errorCode) where errorCode == EEXIST {
                // A non-cooperating writer may have published after our
                // existence check. Validate and reuse or rotate its value.
                return try reuseOrRotateExistingToken()
            }
            return try HelperTokenLoader.load(from: tokenFileURL.path)
        }
    }

    private func reuseOrRotateExistingToken() throws -> String {
        let existing = try HelperTokenLoader.load(from: tokenFileURL.path)
        guard Self.isPairingCompatible(existing) == false else { return existing }

        // A legacy token that the loader accepts but one-click pairing rejects
        // (pairing requires exactly 64 hex). Atomically replace it so readers
        // see either the complete old token or the complete new token.
        FileHandle.standardError.write(Data("langtools: rotating legacy helper token to 64-hex format\n".utf8))
        try Self.replace(token: Self.generateToken(), at: tokenFileURL)
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

    /// Publishes a complete token without replacing an existing target.
    /// `link(2)` is atomic and the staging file is in the same directory, so a
    /// reader sees either no target or the complete owner-only token.
    static func publish(token: String, at url: URL) throws {
        let temporaryURL = try writeTemporaryToken(token, for: url)
        defer { _ = unlink(temporaryURL.path) }

        guard link(temporaryURL.path, url.path) == 0 else {
            let errorCode = errno
            throw TokenFileControllerError.publishFailed(path: url.path, errno: errorCode)
        }
    }

    /// Atomically replaces a loader-valid legacy token. Readers see either the
    /// complete legacy value or the complete replacement.
    static func replace(token: String, at url: URL) throws {
        let temporaryURL = try writeTemporaryToken(token, for: url)
        defer { _ = unlink(temporaryURL.path) }

        guard rename(temporaryURL.path, url.path) == 0 else {
            let errorCode = errno
            throw TokenFileControllerError.replaceFailed(path: url.path, errno: errorCode)
        }
    }

    private static func writeTemporaryToken(_ token: String, for url: URL) throws -> URL {
        try ensureParentDirectory(for: url)
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).tmp.\(UUID().uuidString)"
        )
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            let errorCode = errno
            throw TokenFileControllerError.createFailed(path: temporaryURL.path, errno: errorCode)
        }

        var closed = false
        var complete = false
        defer {
            if closed == false { _ = close(descriptor) }
            if complete == false { _ = unlink(temporaryURL.path) }
        }

        guard fchmod(descriptor, 0o600) == 0 else {
            let errorCode = errno
            throw TokenFileControllerError.createFailed(path: temporaryURL.path, errno: errorCode)
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
                    let errorCode = errno
                    if errorCode == EINTR { continue }
                    throw TokenFileControllerError.writeFailed(path: temporaryURL.path, errno: errorCode)
                }
                guard written > 0 else {
                    throw TokenFileControllerError.writeFailed(path: temporaryURL.path, errno: EIO)
                }
                offset += written
            }
        }

        guard fsync(descriptor) == 0 else {
            let errorCode = errno
            throw TokenFileControllerError.writeFailed(path: temporaryURL.path, errno: errorCode)
        }

        let closeResult = close(descriptor)
        let closeError = errno
        closed = true
        guard closeResult == 0 else {
            throw TokenFileControllerError.writeFailed(path: temporaryURL.path, errno: closeError)
        }
        complete = true
        return temporaryURL
    }

    private static func ensureParentDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
    }

    private static func withExclusiveLock<Result>(
        at url: URL,
        perform body: () throws -> Result
    ) throws -> Result {
        processLock.lock()
        defer { processLock.unlock() }

        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            let errorCode = errno
            throw TokenFileControllerError.lockFailed(path: url.path, errno: errorCode)
        }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let errorCode = errno
            throw TokenFileControllerError.lockFailed(path: url.path, errno: errorCode)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1
        else {
            throw TokenFileControllerError.lockFailed(path: url.path, errno: EPERM)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            let errorCode = errno
            throw TokenFileControllerError.lockFailed(path: url.path, errno: errorCode)
        }

        while setRecordLock(descriptor, type: F_WRLCK, command: F_SETLKW) != 0 {
            let errorCode = errno
            if errorCode == EINTR { continue }
            throw TokenFileControllerError.lockFailed(path: url.path, errno: errorCode)
        }
        defer { _ = setRecordLock(descriptor, type: F_UNLCK, command: F_SETLK) }

        return try body()
    }

    private static func setRecordLock(_ descriptor: Int32, type: Int32, command: Int32) -> Int32 {
        var lock = flock()
        lock.l_type = Int16(type)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        return fcntl(descriptor, command, &lock)
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
