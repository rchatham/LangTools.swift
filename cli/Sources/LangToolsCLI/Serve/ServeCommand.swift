import Foundation
import HelperCore

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