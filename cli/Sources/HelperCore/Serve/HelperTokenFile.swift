#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Loads the helper bearer token from a mode-0600, user-owned file.
///
/// The token never appears in argv or environment, so the file is the single
/// trust boundary: it must be a regular file owned by the effective user with
/// no group or other permissions, bounded in size, and contain a single valid
/// UTF-8 line.
public struct HelperTokenLoader {
    public static let maximumTokenBytes = 4_096

    public static func load(from path: String) throws -> String {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw HelperTokenFileError.cannotOpen }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw HelperTokenFileError.cannotInspect }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw HelperTokenFileError.notRegularFile }
        guard metadata.st_uid == geteuid() else { throw HelperTokenFileError.wrongOwner }
        guard metadata.st_mode & 0o077 == 0 else { throw HelperTokenFileError.insecurePermissions }
        guard metadata.st_size <= maximumTokenBytes else { throw HelperTokenFileError.tooLarge }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(1_024, maximumTokenBytes + 1))
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw HelperTokenFileError.cannotRead
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= maximumTokenBytes else { throw HelperTokenFileError.tooLarge }
        }

        if data.last == UInt8(ascii: "\n") {
            data.removeLast()
            if data.last == UInt8(ascii: "\r") { data.removeLast() }
        }
        guard data.isEmpty == false else { throw HelperTokenFileError.empty }
        guard data.contains(0) == false,
              data.contains(UInt8(ascii: "\n")) == false,
              data.contains(UInt8(ascii: "\r")) == false,
              let token = String(data: data, encoding: .utf8)
        else { throw HelperTokenFileError.invalidContents }
        return token
    }
}

public enum HelperTokenFileError: LocalizedError {
    case cannotOpen
    case cannotInspect
    case notRegularFile
    case wrongOwner
    case insecurePermissions
    case tooLarge
    case cannotRead
    case empty
    case invalidContents

    public var errorDescription: String? {
        switch self {
        case .cannotOpen: return "Unable to securely open the helper token file."
        case .cannotInspect: return "Unable to inspect the helper token file."
        case .notRegularFile: return "The helper token file must be a regular file."
        case .wrongOwner: return "The helper token file must be owned by the effective user."
        case .insecurePermissions: return "The helper token file must not grant group or other permissions."
        case .tooLarge: return "The helper token file exceeds the size limit."
        case .cannotRead: return "Unable to read the helper token file."
        case .empty: return "The helper token file must not be empty."
        case .invalidContents: return "The helper token file must contain one valid UTF-8 line without NUL bytes."
        }
    }
}