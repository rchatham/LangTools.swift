//
//  AgentSpool.swift
//  AgentRuntime
//
//  A directory-backed job queue for `langtools-agent worker`. Jobs move between
//  subdirectories by atomic rename, so a job is in exactly one state and survives a
//  worker restart:
//
//      <spool>/incoming/  written here first, then renamed into queue/
//      <spool>/queue/     waiting; claimed oldest first
//      <spool>/running/   claimed by the worker
//      <spool>/done/      results, as AgentRunResult JSON named <runID>.json
//

import Foundation

/// A spec queued for a worker, with where to send its result.
public struct AgentJob: Codable, Equatable, Sendable {
    public var runID: String
    public var spec: AgentSpec
    public var webhookURL: URL?
    /// Overrides the worker's `LANGTOOLS_WEBHOOK_SECRET` for this job. Kept only in the
    /// job file, which the spool writes readable by its owner alone.
    public var webhookSecret: String?
    /// Who submitted the job, for audit; workers do not enforce it.
    public var owner: String?
    public var submittedAt: Date
    /// How many times a worker has started this job. A job interrupted by a restart is
    /// started once more, then reported as failed.
    public var attempts: Int

    public init(runID: String = UUID().uuidString, spec: AgentSpec, webhookURL: URL? = nil, webhookSecret: String? = nil, owner: String? = nil, submittedAt: Date = Date(), attempts: Int = 0) {
        self.runID = runID
        self.spec = spec
        self.webhookURL = webhookURL
        self.webhookSecret = webhookSecret
        self.owner = owner
        self.submittedAt = submittedAt
        self.attempts = attempts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decodeIfPresent(String.self, forKey: .runID) ?? UUID().uuidString
        spec = try container.decode(AgentSpec.self, forKey: .spec)
        webhookURL = try container.decodeIfPresent(URL.self, forKey: .webhookURL)
        webhookSecret = try container.decodeIfPresent(String.self, forKey: .webhookSecret)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        submittedAt = try container.decodeIfPresent(Date.self, forKey: .submittedAt) ?? Date()
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
    }

    /// Run IDs become file names, so they are limited to letters, digits, `.`, `_` and `-`.
    public static func isValidRunID(_ runID: String) -> Bool {
        (1...128).contains(runID.count) && !runID.hasPrefix(".")
            && runID.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0) }
    }

    public func validate() throws {
        guard Self.isValidRunID(runID) else {
            throw AgentRuntimeError.invalidSpec("Run ID '\(runID)' must be 1-128 letters, digits, '.', '_' or '-', not starting with '.'.")
        }
        try spec.validateStructure()
        if let webhookURL { _ = try WebhookConfiguration(url: webhookURL, secret: webhookSecret) }
    }

    public static func decode(from data: Data) throws -> AgentJob {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentJob.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public struct AgentSpool {
    public enum State: String, Codable, Sendable {
        case queued, running, done, unknown
    }

    public let root: URL
    private let fileManager = FileManager.default

    public init(root: URL) {
        self.root = root
    }

    var incoming: URL { root.appendingPathComponent("incoming", isDirectory: true) }
    var queue: URL { root.appendingPathComponent("queue", isDirectory: true) }
    var running: URL { root.appendingPathComponent("running", isDirectory: true) }
    var done: URL { root.appendingPathComponent("done", isDirectory: true) }

    public func prepare() throws {
        for directory in [incoming, queue, running, done] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Adds a job to the queue. Fails if a job or result with the same run ID exists.
    public func enqueue(_ job: AgentJob) throws {
        try job.validate()
        try prepare()
        guard state(of: job.runID) == .unknown else { throw AgentRuntimeError.invalidSpec("A job with run ID '\(job.runID)' already exists.") }
        let name = Self.fileName(for: job)
        let staged = incoming.appendingPathComponent(name)
        guard fileManager.createFile(atPath: staged.path, contents: try job.encoded(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staged.path])
        }
        do { try fileManager.moveItem(at: staged, to: queue.appendingPathComponent(name)) }
        catch { try? fileManager.removeItem(at: staged); throw error }
    }

    /// Moves the oldest queued job to running/ and returns it, or nil when the queue is empty.
    /// A rename is atomic, so two workers sharing a spool never claim the same job.
    func claimNext() throws -> (job: AgentJob, file: URL)? {
        for name in try sortedJSON(in: queue) {
            let claimed = running.appendingPathComponent(name)
            do { try fileManager.moveItem(at: queue.appendingPathComponent(name), to: claimed) }
            catch { continue }  // Another worker took it.
            do {
                var job = try AgentJob.decode(from: Data(contentsOf: claimed))
                job.attempts += 1
                try rewrite(job, at: claimed)
                return (job, claimed)
            } catch {
                try? quarantine(claimed)
            }
        }
        return nil
    }

    /// Records the result and removes the job file.
    func complete(_ file: URL, result: AgentRunResult) throws {
        try write(result)
        try fileManager.removeItem(at: file)
    }

    func write(_ result: AgentRunResult) throws {
        guard let runID = result.runID, AgentJob.isValidRunID(runID) else { return }
        let destination = done.appendingPathComponent("\(runID).json")
        let staged = incoming.appendingPathComponent(".\(runID).result")
        guard fileManager.createFile(atPath: staged.path, contents: try result.encoded(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staged.path])
        }
        // rename(2) replaces an existing result in one step, so a reader never finds it missing.
        guard rename(staged.path, destination.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: staged)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
    }

    /// Jobs left in running/ by a worker that stopped mid-run. Each is returned to the
    /// queue, or reported failed if it has already been started `maxAttempts` times.
    func recoverInterrupted(maxAttempts: Int) throws -> (requeued: [AgentJob], abandoned: [(job: AgentJob, file: URL)]) {
        var requeued: [AgentJob] = []
        var abandoned: [(job: AgentJob, file: URL)] = []
        for name in try sortedJSON(in: running) {
            let file = running.appendingPathComponent(name)
            guard let job = try? AgentJob.decode(from: Data(contentsOf: file)) else {
                try? quarantine(file)
                continue
            }
            if job.attempts >= maxAttempts {
                abandoned.append((job, file))
            } else {
                try fileManager.moveItem(at: file, to: queue.appendingPathComponent(name))
                requeued.append(job)
            }
        }
        return (requeued, abandoned)
    }

    public func state(of runID: String) -> State {
        guard AgentJob.isValidRunID(runID) else { return .unknown }
        if fileManager.fileExists(atPath: done.appendingPathComponent("\(runID).json").path) { return .done }
        func holds(_ directory: URL) -> Bool {
            ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).contains { Self.runID(fromFileName: $0) == runID }
        }
        if holds(running) { return .running }
        if holds(queue) { return .queued }
        return .unknown
    }

    public func result(for runID: String) throws -> AgentRunResult? {
        guard AgentJob.isValidRunID(runID) else { return nil }
        let file = done.appendingPathComponent("\(runID).json")
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        return try AgentRunResult.decode(from: Data(contentsOf: file))
    }

    /// Deletes results older than `age`.
    func pruneResults(olderThan age: TimeInterval, now: Date = Date()) throws {
        for name in try sortedJSON(in: done) {
            let file = done.appendingPathComponent(name)
            let modified = try fileManager.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
            if let modified, now.timeIntervalSince(modified) > age { try fileManager.removeItem(at: file) }
        }
    }

    // Submission time first so the queue is FIFO; the run ID keeps names unique.
    static func fileName(for job: AgentJob) -> String {
        "\(String(format: "%013.0f", job.submittedAt.timeIntervalSince1970 * 1000))-\(job.runID).json"
    }

    /// The run ID in a name made by `fileName(for:)`. The timestamp has no '-', so the run
    /// ID is everything after the first one; matching a suffix would confuse "1" with "job-1".
    static func runID(fromFileName name: String) -> String? {
        guard name.hasSuffix(".json"), let dash = name.firstIndex(of: "-") else { return nil }
        let runID = String(name[name.index(after: dash)..<name.index(name.endIndex, offsetBy: -5)])
        return runID.isEmpty ? nil : runID
    }

    private func sortedJSON(in directory: URL) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
    }

    private func rewrite(_ job: AgentJob, at file: URL) throws {
        try job.encoded().write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // A file the worker cannot read is set aside rather than retried forever.
    private func quarantine(_ file: URL) throws {
        try fileManager.moveItem(at: file, to: done.appendingPathComponent(".invalid-\(file.lastPathComponent)"))
    }
}
