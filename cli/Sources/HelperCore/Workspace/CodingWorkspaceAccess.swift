import Foundation
import Security

/// Local-helper-only authorization. Never expose enable/addRoot through chat or
/// mobile routes. Roots constrain launch directories, NOT the filesystem access
/// of an arbitrary executable; the helper's consent UI must explain that fact.
public actor CodingWorkspaceAccess {
    public struct Root: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let path: String
    }

    public enum AccessError: Error, LocalizedError, Equatable {
        case disabled, unauthorized, invalidDirectory, outsideRoot, unknownRoot, randomFailure

        public var errorDescription: String? {
            switch self {
            case .disabled: return "Enable Coding Workspace in LangTools Helper first."
            case .unauthorized: return "The coding-workspace credential is missing or expired."
            case .invalidDirectory: return "Select an existing absolute project directory."
            case .outsideRoot: return "The working directory is outside the approved project root."
            case .unknownRoot: return "Approve this project in LangTools Helper first."
            case .randomFailure: return "Unable to create a secure workspace credential."
            }
        }
    }

    private var token: String?
    private var roots: [UUID: Root] = [:]

    public init() {}

    /// Called only after local user consent. Each enable rotates the credential
    /// and clears previous roots. Grants are intentionally not persisted.
    public func enable() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AccessError.randomFailure
        }
        let credential = Data(bytes).base64EncodedString()
        roots.removeAll()
        token = credential
        return credential
    }

    public func disable() {
        token = nil
        roots.removeAll()
    }

    /// Local consent entry point, not a network operation.
    public func addRoot(path: String) throws -> Root {
        guard token != nil else { throw AccessError.disabled }
        let canonical = try Self.canonicalDirectory(path)
        if let existing = roots.values.first(where: { $0.path == canonical }) { return existing }
        let root = Root(id: UUID(), path: canonical)
        roots[root.id] = root
        return root
    }

    public func removeRoot(id: UUID) {
        roots.removeValue(forKey: id)
    }

    public func approvedRoots(credential: String?) throws -> [Root] {
        try authenticate(credential)
        return roots.values.sorted { $0.path < $1.path }
    }

    /// Revalidate on every launch/attach/input/resize/stop operation. A caller
    /// must not cache successful authorization across an await or revocation.
    public func authorize(credential: String?, rootID: UUID, directory: String) throws -> String {
        try authenticate(credential)
        guard let root = roots[rootID] else { throw AccessError.unknownRoot }
        // Reject roots replaced with symlinks since consent.
        guard try Self.canonicalDirectory(root.path) == root.path else { throw AccessError.outsideRoot }
        let canonical = try Self.canonicalDirectory(directory)
        let rootComponents = URL(fileURLWithPath: root.path).pathComponents
        let components = URL(fileURLWithPath: canonical).pathComponents
        guard components.starts(with: rootComponents) else { throw AccessError.outsideRoot }
        return canonical
    }

    private func authenticate(_ credential: String?) throws {
        guard let token else { throw AccessError.disabled }
        guard SecureTokenComparison.matches(expected: token, provided: credential) else {
            throw AccessError.unauthorized
        }
    }

    private static func canonicalDirectory(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              let resolved = realpath(path, nil) else { throw AccessError.invalidDirectory }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw AccessError.invalidDirectory }
        return canonical
    }
}
