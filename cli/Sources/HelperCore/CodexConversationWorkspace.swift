import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct CodexConversationWorkspace: Sendable {
    typealias CleanupFailureHandler = @Sendable (URL, Error) -> Void

    private let cacheRoot: URL
    let processRoot: URL
    private let cleanupFailureHandler: CleanupFailureHandler
    private let lease = CodexWorkspaceLease()

    init(
        cacheRoot: URL? = nil,
        processID: UUID = UUID(),
        staleProcessAge: TimeInterval = 86_400,
        now: Date = Date(),
        cleanupFailureHandler: @escaping CleanupFailureHandler = { url, error in
            NSLog("Unable to clean Codex workspace at %@: %@", url.path, error.localizedDescription)
        }
    ) {
        let userCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Caches", isDirectory: true)
        self.cacheRoot = cacheRoot ?? userCache
            .appendingPathComponent("LangToolsCLI/CodexWorkspaces", isDirectory: true)
        self.processRoot = self.cacheRoot
            .appendingPathComponent("process-\(processID.uuidString.lowercased())", isDirectory: true)
            .standardizedFileURL
        self.cleanupFailureHandler = cleanupFailureHandler
        scavengeStaleProcessRoots(olderThan: staleProcessAge, now: now)
        do {
            try createPrivateDirectory(at: processRoot)
            try lease.acquire(at: processRoot.appendingPathComponent(".owner.lock"))
        } catch {
            cleanupFailureHandler(processRoot, error)
        }
    }

    func createWorkspace(for conversationID: UUID) throws -> URL {
        guard lease.isHeld else { throw CodexWorkspaceError.lockUnavailable(processRoot.path) }
        try createPrivateDirectory(at: processRoot)
        let workspace = processRoot
            .appendingPathComponent("conversation-\(conversationID.uuidString.lowercased())", isDirectory: true)
            .standardizedFileURL
        try verifyContained(workspace)
        try createPrivateDirectory(at: workspace)
        try verifyContained(workspace.resolvingSymlinksInPath())
        return workspace.resolvingSymlinksInPath()
    }

    func removeWorkspace(_ workspace: URL) {
        do {
            try verifyContained(workspace)
            if FileManager.default.fileExists(atPath: workspace.path) {
                try FileManager.default.removeItem(at: workspace)
            }
        } catch {
            cleanupFailureHandler(workspace, error)
        }
    }

    func removeAllWorkspaces() {
        defer { lease.release() }
        do {
            let root = processRoot.resolvingSymlinksInPath()
            try verifyProcessRoot(root)
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        } catch {
            cleanupFailureHandler(processRoot, error)
        }
    }

    func contains(_ workspace: URL) -> Bool {
        (try? verifyContained(workspace)) != nil
    }

    func releaseLease() {
        lease.release()
    }

    private func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    private func scavengeStaleProcessRoots(olderThan age: TimeInterval, now: Date) {
        guard age >= 0, FileManager.default.fileExists(atPath: cacheRoot.path) else { return }
        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: cacheRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
            let cutoff = now.addingTimeInterval(-age)
            for child in children where child.standardizedFileURL != processRoot {
                do {
                    guard isExactDirectProcessRoot(child) else { continue }
                    let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
                    guard attributes[.type] as? FileAttributeType == .typeDirectory,
                          let modified = attributes[.modificationDate] as? Date,
                          modified <= cutoff
                    else { continue }
                    let staleLease = CodexWorkspaceLease()
                    guard try staleLease.tryAcquire(at: child.appendingPathComponent(".owner.lock")) else { continue }
                    try FileManager.default.removeItem(at: child)
                    staleLease.release()
                } catch {
                    cleanupFailureHandler(child, error)
                }
            }
        } catch {
            cleanupFailureHandler(cacheRoot, error)
        }
    }

    private func isExactDirectProcessRoot(_ candidate: URL) -> Bool {
        let base = cacheRoot.standardizedFileURL
        let child = candidate.standardizedFileURL
        let name = child.lastPathComponent
        guard child.pathComponents.count == base.pathComponents.count + 1,
              Array(child.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents,
              name.hasPrefix("process-"),
              let id = UUID(uuidString: String(name.dropFirst("process-".count)))
        else { return false }
        return name == "process-\(id.uuidString.lowercased())"
    }

    private func verifyContained(_ workspace: URL) throws {
        let root = processRoot.resolvingSymlinksInPath().standardizedFileURL
        try verifyProcessRoot(root)
        let candidate = workspace.resolvingSymlinksInPath().standardizedFileURL
        let name = candidate.lastPathComponent
        guard candidate.pathComponents.count == root.pathComponents.count + 1,
              Array(candidate.pathComponents.prefix(root.pathComponents.count)) == root.pathComponents,
              name.hasPrefix("conversation-"),
              UUID(uuidString: String(name.dropFirst("conversation-".count))) != nil
        else {
            throw CodexWorkspaceError.outsideProcessRoot(candidate.path)
        }
    }

    private func verifyProcessRoot(_ root: URL) throws {
        let base = cacheRoot.resolvingSymlinksInPath().standardizedFileURL
        let name = root.lastPathComponent
        guard root.pathComponents.count == base.pathComponents.count + 1,
              Array(root.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents,
              name.hasPrefix("process-"),
              UUID(uuidString: String(name.dropFirst("process-".count))) != nil
        else {
            throw CodexWorkspaceError.invalidProcessRoot(root.path)
        }
    }
}

private final class CodexWorkspaceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0
    }

    deinit {
        release()
    }

    func acquire(at url: URL) throws {
        guard try tryAcquire(at: url) else {
            throw CodexWorkspaceError.lockUnavailable(url.deletingLastPathComponent().path)
        }
    }

    func tryAcquire(at url: URL) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 { return true }
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw CodexWorkspaceError.lockUnavailable(url.path) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

enum CodexWorkspaceError: LocalizedError, Sendable {
    case invalidProcessRoot(String)
    case outsideProcessRoot(String)
    case lockUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidProcessRoot(let path): return "Invalid Codex process workspace root: \(path)"
        case .outsideProcessRoot(let path): return "Refusing to access a Codex workspace outside the process root: \(path)"
        case .lockUnavailable(let path): return "Unable to acquire the Codex workspace ownership lock: \(path)"
        }
    }
}
