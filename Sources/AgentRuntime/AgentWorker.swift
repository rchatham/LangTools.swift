//
//  AgentWorker.swift
//  AgentRuntime
//
//  A long-lived process that runs jobs from an `AgentSpool`, writes each result to the
//  spool and delivers it to the job's webhook.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Mutable state is behind a lock; makeWebhookDelivery is set before run() and only read after.
public final class AgentWorker: @unchecked Sendable {
    public struct Options {
        /// Jobs run at the same time.
        public var concurrency: Int
        /// How often an idle worker checks the queue.
        public var pollInterval: TimeInterval
        /// Results older than this are deleted from the spool.
        public var resultRetention: TimeInterval
        /// Starts per job, counting the first; an interrupted job is retried until this is reached.
        public var maxAttempts: Int
        /// Used when a job has no `webhookSecret` of its own.
        public var webhookSecret: String?

        public init(concurrency: Int = 2, pollInterval: TimeInterval = 1, resultRetention: TimeInterval = 7 * 24 * 3600, maxAttempts: Int = 2, webhookSecret: String? = nil) {
            self.concurrency = max(1, concurrency)
            self.pollInterval = pollInterval
            self.resultRetention = resultRetention
            self.maxAttempts = max(1, maxAttempts)
            self.webhookSecret = webhookSecret
        }
    }

    public let spool: AgentSpool
    public let runner: AgentRunner
    public let options: Options
    var makeWebhookDelivery: (WebhookConfiguration) -> WebhookDelivery
    private let log: (String) -> Void
    private let lock = NSLock()
    private var stopping = false
    private var active = 0

    public init(spool: AgentSpool, runner: AgentRunner, options: Options = Options(), session: URLSession = URLSession(configuration: .default), log: @escaping (String) -> Void = { print($0) }) {
        self.spool = spool
        self.runner = runner
        self.options = options
        self.log = log
        self.makeWebhookDelivery = { WebhookDelivery(configuration: $0, session: session) }
    }

    /// Stops claiming new jobs; `run()` returns once the jobs already running finish.
    public func stop() {
        lock.lock(); stopping = true; lock.unlock()
    }

    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    private var activeCount: Int { lock.lock(); defer { lock.unlock() }; return active }
    private func adjustActive(_ delta: Int) { lock.lock(); active += delta; lock.unlock() }

    /// Processes jobs until `stop()` is called.
    public func run() async throws {
        try spool.prepare()
        try await recover()
        log("worker started: spool=\(spool.root.path) concurrency=\(options.concurrency)")

        var lastPrune = Date.distantPast
        await withTaskGroup(of: Void.self) { group in
            while !isStopping {
                if Date().timeIntervalSince(lastPrune) > 3600 {
                    do { try spool.pruneResults(olderThan: options.resultRetention) } catch { log("warning: could not prune results: \(error)") }
                    lastPrune = Date()
                }
                var claimedAny = false
                while activeCount < options.concurrency, !isStopping {
                    let claimed: (job: AgentJob, file: URL)?
                    do { claimed = try spool.claimNext() } catch { log("error: could not read queue: \(error)"); break }
                    guard let claimed else { break }
                    claimedAny = true
                    adjustActive(1)
                    group.addTask {
                        await self.process(claimed.job, file: claimed.file)
                        self.adjustActive(-1)
                    }
                }
                if !claimedAny { try? await Task.sleep(nanoseconds: UInt64(options.pollInterval * 1_000_000_000)) }
            }
            log("worker stopping: waiting for \(activeCount) running job(s)")
            await group.waitForAll()
        }
        log("worker stopped")
    }

    func process(_ job: AgentJob, file: URL) async {
        log("run=\(job.runID) started agent=\(job.spec.name) attempt=\(job.attempts)")
        var result = await runner.run(job.spec)
        result.runID = job.runID
        do { try spool.complete(file, result: result) }
        catch { log("run=\(job.runID) error: could not save result: \(error)") }
        log("run=\(job.runID) \(result.status.rawValue)\(result.error.map { ": \($0)" } ?? "")")
        await deliver(result, for: job)
    }

    // A job left running by a stopped worker is retried, or reported failed once it has
    // used its attempts, since a tool it called may already have had side effects.
    private func recover() async throws {
        let (requeued, abandoned) = try spool.recoverInterrupted(maxAttempts: options.maxAttempts)
        for job in requeued { log("run=\(job.runID) requeued after an interrupted attempt") }
        for (job, file) in abandoned {
            let now = Date()
            let result = AgentRunResult(runID: job.runID, agent: job.spec.name, provider: job.spec.provider.rawValue, model: job.spec.model, status: .failed,
                                        error: "The worker stopped during the run \(job.attempts) time(s); not retrying.", startedAt: now, finishedAt: now)
            try spool.complete(file, result: result)
            log("run=\(job.runID) failed: interrupted \(job.attempts) time(s)")
            await deliver(result, for: job)
        }
    }

    private func deliver(_ result: AgentRunResult, for job: AgentJob) async {
        guard let url = job.webhookURL else { return }
        do {
            let configuration = try WebhookConfiguration(url: url, secret: job.webhookSecret ?? options.webhookSecret)
            let outcome = await makeWebhookDelivery(configuration).deliver(result)
            if outcome.delivered { log("run=\(job.runID) delivered to webhook (\(outcome.attempts) attempt(s))") }
            else { log("run=\(job.runID) error: webhook delivery failed after \(outcome.attempts) attempt(s): \(outcome.error ?? "unknown error")") }
        } catch {
            log("run=\(job.runID) error: \(error.localizedDescription)")
        }
    }
}
