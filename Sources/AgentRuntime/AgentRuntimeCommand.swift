//
//  AgentRuntimeCommand.swift
//  AgentRuntime
//
//  The command-line front end shared by `langtools-agent` and custom runtimes. A custom
//  runtime registers its own tools and providers and hands them to this command:
//
//      var tools = AgentToolRegistry.builtIn
//      tools.register(myTool)
//      let command = AgentRuntimeCommand(providers: .builtIn, tools: tools)
//      exit(await command.run(Array(CommandLine.arguments.dropFirst())))
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AgentRuntimeCommand {
    public enum ExitCode: Int32 {
        case success = 0
        /// The run failed or timed out.
        case runFailed = 1
        /// Bad arguments, an invalid spec, or an invalid webhook URL.
        case usage = 2
        /// The result could not be delivered to the webhook, whatever the run's outcome.
        case deliveryFailed = 3
    }

    public static let webhookURLVariable = "LANGTOOLS_WEBHOOK_URL"
    public static let webhookSecretVariable = "LANGTOOLS_WEBHOOK_SECRET"
    public static let runIDVariable = "LANGTOOLS_RUN_ID"
    public static let spoolVariable = "LANGTOOLS_SPOOL_DIR"

    public var providers: AgentProviderRegistry
    public var tools: AgentToolRegistry
    public var environment: [String: String]
    public var session: URLSession
    public var readFile: (String) throws -> Data
    public var writeFile: (Data, String) throws -> Void
    public var standardInput: () -> Data
    public var standardOutput: (String) -> Void
    public var standardError: (String) -> Void
    var makeWebhookDelivery: (WebhookConfiguration, URLSession) -> WebhookDelivery = { WebhookDelivery(configuration: $0, session: $1) }
    /// Calls the handler on SIGTERM or SIGINT so a worker can finish its running jobs.
    var onStopSignal: (@escaping () -> Void) -> Void = AgentRuntimeCommand.installStopSignalHandler

    public init(
        providers: AgentProviderRegistry,
        tools: AgentToolRegistry = .builtIn,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = URLSession(configuration: .default),
        readFile: @escaping (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) },
        writeFile: @escaping (Data, String) throws -> Void = { try $0.write(to: URL(fileURLWithPath: $1), options: .atomic) },
        standardInput: @escaping () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
        standardOutput: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        standardError: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.providers = providers
        self.tools = tools
        self.environment = environment
        self.session = session
        self.readFile = readFile
        self.writeFile = writeFile
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public static let usage = """
        Usage: langtools-agent <command> [options]

        Commands:
          run <spec.json | ->      Run an agent spec and print the result as JSON.
              --output <file>      Write the result to a file instead of standard output.
              --quiet              Do not print progress events to standard error.
              --webhook <url>      POST the result to this URL (or set LANGTOOLS_WEBHOOK_URL).
              --run-id <id>        Label the result for the webhook receiver (or set LANGTOOLS_RUN_ID).
          validate <spec.json | -> Check a spec, its provider, model, tools and API key without running it.
              --webhook <url>      Also check the webhook URL.
          worker                   Run jobs from a spool directory until stopped (SIGTERM or SIGINT).
              --spool <dir>        The spool (or set LANGTOOLS_SPOOL_DIR).
              --concurrency <n>    Jobs to run at once (default 2).
              --poll-interval <s>  Seconds between queue checks when idle (default 1).
          enqueue <spec.json | ->  Validate a spec and add it to the spool; prints the run ID.
              --spool <dir>        The spool (or set LANGTOOLS_SPOOL_DIR).
              --webhook <url>      Where the worker should POST the result.
              --run-id <id>        The run ID to use (default: a new UUID).
              --owner <name>       Recorded with the job for audit.
              --job                Read a whole job (spec, webhook, secret) as JSON instead of a spec.
          status <run-id>          Print a job's state, and its result once done.
              --spool <dir>        The spool (or set LANGTOOLS_SPOOL_DIR).
          providers                List registered providers and their API key variables.
          tools                    List registered tools.

        API keys are read from each provider's environment variable, never from the spec.
        Webhook deliveries are signed with LANGTOOLS_WEBHOOK_SECRET when it is set.
        Exit status: 0 success, 1 run failed or timed out, 2 usage or invalid spec,
        3 the result could not be delivered to the webhook. status exits 1 for an unknown run ID.
        """

    /// Runs the command for `arguments`, which excludes the executable name.
    public func run(_ arguments: [String]) async -> Int32 {
        await execute(arguments).rawValue
    }

    private func execute(_ arguments: [String]) async -> ExitCode {
        guard let command = arguments.first else { return usageError(nil) }
        var options = Array(arguments.dropFirst())
        switch command {
        case "run":
            let quiet = take(flag: "--quiet", from: &options)
            let outputPath, webhookURL, runID: String?
            do {
                outputPath = try take(option: "--output", from: &options)
                webhookURL = try take(option: "--webhook", from: &options)
                runID = try take(option: "--run-id", from: &options)
            } catch { return usageError(error.localizedDescription) }
            guard options.count == 1 else { return usageError("run takes one spec path.") }
            return await runSpec(at: options[0], outputPath: outputPath, quiet: quiet, webhookURL: webhookURL, runID: runID)
        case "validate":
            let webhookURL: String?
            do { webhookURL = try take(option: "--webhook", from: &options) }
            catch { return usageError(error.localizedDescription) }
            guard options.count == 1 else { return usageError("validate takes one spec path.") }
            return validateSpec(at: options[0], webhookURL: webhookURL)
        case "worker":
            return await runWorker(&options)
        case "enqueue":
            return enqueue(&options)
        case "status":
            return status(&options)
        case "providers":
            for registration in providers.all {
                let key = registration.apiKeyEnvironmentVariable.map { registration.requiresAPIKey ? $0 : "\($0) (optional)" } ?? "no key"
                standardOutput("\(registration.id.rawValue)\t\(registration.displayName)\t\(key)")
            }
            return .success
        case "tools":
            for tool in tools.all { standardOutput("\(tool.name)\t\(tool.description ?? "")") }
            return .success
        case "help", "--help", "-h":
            standardOutput(Self.usage)
            return .success
        default:
            return usageError("Unknown command '\(command)'.")
        }
    }

    private func runSpec(at path: String, outputPath: String?, quiet: Bool, webhookURL: String?, runID: String?) async -> ExitCode {
        let spec: AgentSpec
        let webhook: WebhookConfiguration?
        do {
            spec = try loadSpec(at: path)
            // Checked before the run so a bad URL doesn't cost a provider call.
            webhook = try webhookConfiguration(webhookURL)
        } catch { standardError("error: \(error.localizedDescription)"); return .usage }
        if let webhook, webhook.secret == nil, !quiet {
            standardError("warning: \(Self.webhookSecretVariable) is not set; the webhook delivery will be unsigned.")
        }

        let runner = AgentRunner(
            providers: providers,
            tools: tools,
            credentials: .environment(environment),
            session: session,
            onEvent: { event in if !quiet { standardError(Self.describe(event)) } }
        )
        var result = await runner.run(spec)
        result.runID = runID ?? environment[Self.runIDVariable] ?? UUID().uuidString

        do {
            let data = try result.encoded()
            if let outputPath { try writeFile(data, outputPath) }
            else { standardOutput(String(decoding: data, as: UTF8.self)) }
        } catch {
            standardError("error: could not write result: \(error.localizedDescription)")
            return .runFailed
        }

        if let webhook {
            let outcome = await makeWebhookDelivery(webhook, session).deliver(result)
            guard outcome.delivered else {
                standardError("error: webhook delivery failed after \(outcome.attempts) attempt(s): \(outcome.error ?? "unknown error")")
                return .deliveryFailed
            }
            if !quiet { standardError("[\(spec.name)] delivered result to webhook (\(outcome.attempts) attempt(s))") }
        }

        switch result.status {
        case .completed: return .success
        case .failed, .timedOut:
            standardError("error: \(result.error ?? result.status.rawValue)")
            return .runFailed
        case .invalid:
            standardError("error: \(result.error ?? "invalid spec")")
            return .usage
        }
    }

    private func validateSpec(at path: String, webhookURL: String?) -> ExitCode {
        do {
            let spec = try loadSpec(at: path)
            _ = try webhookConfiguration(webhookURL)
            try AgentRunner(providers: providers, tools: tools, credentials: .environment(environment), session: session).validate(spec)
            standardOutput("\(spec.name): ok")
            return .success
        } catch {
            standardError("error: \(error.localizedDescription)")
            return .usage
        }
    }

    // MARK: - Worker

    private func spool(_ options: inout [String]) throws -> AgentSpool {
        guard let path = try take(option: "--spool", from: &options) ?? environment[Self.spoolVariable], !path.isEmpty else {
            throw AgentRuntimeError.invalidSpec("Set --spool or \(Self.spoolVariable).")
        }
        return AgentSpool(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func runWorker(_ options: inout [String]) async -> ExitCode {
        let spool: AgentSpool
        var workerOptions = AgentWorker.Options(webhookSecret: environment[Self.webhookSecretVariable])
        do {
            spool = try self.spool(&options)
            if let value = try take(option: "--concurrency", from: &options) {
                guard let n = Int(value), n > 0 else { return usageError("--concurrency must be a positive integer.") }
                workerOptions.concurrency = n
            }
            if let value = try take(option: "--poll-interval", from: &options) {
                guard let seconds = Double(value), seconds > 0 else { return usageError("--poll-interval must be a positive number.") }
                workerOptions.pollInterval = seconds
            }
        } catch { return usageError(error.localizedDescription) }
        guard options.isEmpty else { return usageError("Unexpected arguments: \(options.joined(separator: " "))") }
        if workerOptions.webhookSecret == nil { standardError("warning: \(Self.webhookSecretVariable) is not set; jobs without their own secret get unsigned webhook deliveries.") }

        let runner = AgentRunner(providers: providers, tools: tools, credentials: .environment(environment), session: session)
        let worker = AgentWorker(spool: spool, runner: runner, options: workerOptions, session: session, log: standardError)
        let session = self.session
        let makeDelivery = makeWebhookDelivery
        worker.makeWebhookDelivery = { makeDelivery($0, session) }
        onStopSignal { worker.stop() }
        do { try await worker.run() }
        catch {
            standardError("error: \(error.localizedDescription)")
            return .runFailed
        }
        return .success
    }

    private func enqueue(_ options: inout [String]) -> ExitCode {
        do {
            let spool = try self.spool(&options)
            let readsJob = take(flag: "--job", from: &options)
            let webhookURL = try take(option: "--webhook", from: &options)
            let runID = try take(option: "--run-id", from: &options)
            let owner = try take(option: "--owner", from: &options)
            var job: AgentJob
            if readsJob {
                guard options.isEmpty, webhookURL == nil, runID == nil, owner == nil else { return usageError("--job reads everything from standard input; pass no other job options.") }
                job = try AgentJob.decode(from: standardInput())
            } else {
                guard options.count == 1 else { return usageError("enqueue takes one spec path.") }
                job = AgentJob(spec: try loadSpec(at: options[0]), owner: owner)
                if let runID { job.runID = runID }
                if let webhookURL {
                    guard let url = URL(string: webhookURL), url.host != nil else { throw AgentRuntimeError.invalidWebhook("Invalid webhook URL: \(webhookURL)") }
                    job.webhookURL = url
                }
            }
            job.attempts = 0
            // The worker shares this environment, so a missing key or tool is caught now.
            try AgentRunner(providers: providers, tools: tools, credentials: .environment(environment), session: session).validate(job.spec)
            try spool.enqueue(job)
            standardOutput(Self.json(["runID": job.runID, "state": AgentSpool.State.queued.rawValue]))
            return .success
        } catch {
            standardError("error: \(error.localizedDescription)")
            return .usage
        }
    }

    private func status(_ options: inout [String]) -> ExitCode {
        do {
            let spool = try self.spool(&options)
            guard options.count == 1 else { return usageError("status takes one run ID.") }
            let runID = options[0]
            let state = spool.state(of: runID)
            var fields: [String: Any] = ["runID": runID, "state": state.rawValue]
            if state == .done, let result = try spool.result(for: runID) {
                fields["result"] = try JSONSerialization.jsonObject(with: result.encoded(prettyPrinted: false))
            }
            standardOutput(Self.json(fields))
            return state == .unknown ? .runFailed : .success
        } catch {
            standardError("error: \(error.localizedDescription)")
            return .usage
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func installStopSignalHandler(_ handler: @escaping () -> Void) {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler(handler: handler)
            source.resume()
            stopSignalSources.append(source)
        }
    }

    // Signal sources stop delivering once released.
    private static var stopSignalSources: [DispatchSourceSignal] = []

    /// The webhook from `--webhook` or the environment, or nil when neither is set.
    private func webhookConfiguration(_ argument: String?) throws -> WebhookConfiguration? {
        guard let string = argument ?? environment[Self.webhookURLVariable], !string.isEmpty else { return nil }
        guard let url = URL(string: string), url.host != nil else { throw AgentRuntimeError.invalidWebhook("Invalid webhook URL: \(string)") }
        return try WebhookConfiguration(url: url, secret: environment[Self.webhookSecretVariable])
    }

    private func loadSpec(at path: String) throws -> AgentSpec {
        let data: Data
        do { data = path == "-" ? standardInput() : try readFile(path) }
        catch { throw AgentRuntimeError.invalidSpec("Could not read \(path): \(error.localizedDescription)") }
        return try AgentSpec.decode(from: data)
    }

    private func usageError(_ message: String?) -> ExitCode {
        if let message { standardError("error: \(message)") }
        standardError(Self.usage)
        return .usage
    }

    private func take(flag: String, from options: inout [String]) -> Bool {
        guard let index = options.firstIndex(of: flag) else { return false }
        options.remove(at: index)
        return true
    }

    /// The option's value, or nil when it is absent. Throws when it has no value.
    private func take(option: String, from options: inout [String]) throws -> String? {
        guard let index = options.firstIndex(of: option) else { return nil }
        guard options.indices.contains(index + 1) else { throw AgentRuntimeError.invalidSpec("\(option) needs a value.") }
        let value = options[index + 1]
        options.removeSubrange(index...(index + 1))
        return value
    }

    static func describe(_ event: AgentRunResult.Event) -> String {
        let detail = event.detail.map { ": \($0)" } ?? ""
        switch event.kind {
        case .started: return "[\(event.agent)] started\(detail)"
        case .transfer: return "[\(event.agent)] transferred to \(event.target ?? "?")\(detail)"
        case .handoff: return "[\(event.agent)] handed off to \(event.target ?? "?")\(detail)"
        case .toolCalled: return "[\(event.agent)] calling \(event.tool ?? "tool")\(detail)"
        case .toolCompleted: return "[\(event.agent)] tool finished\(detail)"
        case .completed: return "[\(event.agent)] \(event.isError ? "failed" : "completed")"
        case .error: return "[\(event.agent)] error\(detail)"
        }
    }
}
