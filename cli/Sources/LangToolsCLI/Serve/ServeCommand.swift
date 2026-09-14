#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

struct ServeCommand {
    static func run(arguments: [String]) async throws {
        let options = try ServeOptions(arguments: arguments)
        let token = try HelperTokenLoader.load(from: options.tokenFile)
        let server = LocalHelperServer(host: options.host, port: options.port, bearerToken: token)
        try await withTaskCancellationHandler {
            try await server.run()
        } onCancel: {
            Task { await CodexRuntimeService.shared.shutdown() }
        }
    }
}

struct ServeOptions {
    let host: String
    let port: UInt16
    let tokenFile: String

    init(arguments: [String]) throws {
        var host = "127.0.0.1"
        var port: UInt16 = 8765
        var tokenFile: String?
        var seen = Set<String>()
        var index = 0

        while index < arguments.count {
            let flag = arguments[index]
            guard flag != "--token" else { throw ServeOptionsError.deprecatedTokenFlag }
            guard ["--host", "--port", "--token-file"].contains(flag) else {
                throw ServeOptionsError.unknownArgument(flag)
            }
            guard seen.insert(flag).inserted else { throw ServeOptionsError.duplicateOption(flag) }
            guard arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("--") == false else {
                throw ServeOptionsError.missingValue(flag)
            }
            let value = arguments[index + 1]
            switch flag {
            case "--host": host = value
            case "--port":
                guard let parsed = UInt16(value), parsed > 0 else { throw ServeOptionsError.invalidPort(value) }
                port = parsed
            case "--token-file": tokenFile = value
            default: preconditionFailure("Validated option was not handled")
            }
            index += 2
        }

        guard let tokenFile else { throw ServeOptionsError.missingTokenFile }
        self.host = host
        self.port = port
        self.tokenFile = tokenFile
    }
}

struct HelperTokenLoader {
    static let maximumTokenBytes = 4_096

    static func load(from path: String) throws -> String {
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

enum ServeOptionsError: LocalizedError {
    case invalidPort(String)
    case missingTokenFile
    case deprecatedTokenFlag
    case unknownArgument(String)
    case duplicateOption(String)
    case missingValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let value): return "Invalid helper port: \(value)"
        case .missingTokenFile: return "--token-file is required."
        case .deprecatedTokenFlag: return "--token is not supported; use --token-file."
        case .unknownArgument(let value): return "Unknown serve argument: \(value)"
        case .duplicateOption(let value): return "Duplicate serve option: \(value)"
        case .missingValue(let value): return "Missing value for serve option: \(value)"
        }
    }
}

enum HelperTokenFileError: LocalizedError {
    case cannotOpen
    case cannotInspect
    case notRegularFile
    case wrongOwner
    case insecurePermissions
    case tooLarge
    case cannotRead
    case empty
    case invalidContents

    var errorDescription: String? {
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
