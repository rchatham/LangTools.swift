//
//  WebhookDelivery.swift
//  AgentRuntime
//
//  POSTs an `AgentRunResult` to a webhook, signed with HMAC-SHA256 and retried with
//  backoff. Receivers verify the signature with `WebhookSignature.verify`.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto

public struct WebhookConfiguration: Equatable {
    public var url: URL
    /// Signs each delivery. Without one, deliveries are unsigned and anyone who learns
    /// the URL can forge a result.
    public var secret: String?
    public var maxAttempts: Int
    /// The wait before the second attempt; it doubles for each later one, up to `maxBackoff`.
    public var initialBackoff: TimeInterval
    public var maxBackoff: TimeInterval
    /// Per-attempt request timeout.
    public var requestTimeout: TimeInterval

    /// Throws for a URL that isn't HTTPS, except plain HTTP to this machine for local testing.
    public init(url: URL, secret: String?, maxAttempts: Int = 5, initialBackoff: TimeInterval = 1, maxBackoff: TimeInterval = 60, requestTimeout: TimeInterval = 30) throws {
        let scheme = url.scheme?.lowercased()
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw AgentRuntimeError.invalidWebhook("Webhook URL must use https (http is allowed only for localhost): \(url.absoluteString)")
        }
        guard maxAttempts >= 1 else { throw AgentRuntimeError.invalidWebhook("maxAttempts must be at least 1.") }
        self.url = url
        self.secret = secret.flatMap { $0.isEmpty ? nil : $0 }
        self.maxAttempts = maxAttempts
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.requestTimeout = requestTimeout
    }

    /// The wait after a failed attempt: the server's `Retry-After` if given, else exponential backoff; capped at `maxBackoff`.
    public func backoff(afterAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        min(retryAfter ?? initialBackoff * pow(2, Double(attempt - 1)), maxBackoff)
    }
}

public struct WebhookDeliveryOutcome: Equatable {
    public var delivered: Bool
    public var attempts: Int
    /// The last HTTP status received, if any attempt got a response.
    public var statusCode: Int?
    /// Why the last attempt failed.
    public var error: String?
    /// Sent as `X-LangTools-Delivery`; the same on every retry so receivers can drop duplicates.
    public var deliveryID: String
}

public struct WebhookDelivery {
    public static let deliveryHeader = "X-LangTools-Delivery"
    public static let runIDHeader = "X-LangTools-Run-ID"

    public var configuration: WebhookConfiguration
    public var session: URLSession
    var sleep: (TimeInterval) async throws -> Void
    var now: () -> Date

    public init(configuration: WebhookConfiguration, session: URLSession = URLSession(configuration: .default)) {
        self.init(configuration: configuration, session: session, sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }, now: Date.init)
    }

    init(configuration: WebhookConfiguration, session: URLSession, sleep: @escaping (TimeInterval) async throws -> Void, now: @escaping () -> Date) {
        self.configuration = configuration
        self.session = session
        self.sleep = sleep
        self.now = now
    }

    public func deliver(_ result: AgentRunResult, deliveryID: String = UUID().uuidString) async -> WebhookDeliveryOutcome {
        let body: Data
        do { body = try result.encoded(prettyPrinted: false) }
        catch { return WebhookDeliveryOutcome(delivered: false, attempts: 0, error: "Could not encode result: \(error)", deliveryID: deliveryID) }

        var outcome = WebhookDeliveryOutcome(delivered: false, attempts: 0, deliveryID: deliveryID)
        for attempt in 1...configuration.maxAttempts {
            outcome.attempts = attempt
            // Signed per attempt so the timestamp stays inside the receiver's tolerance.
            var request = URLRequest(url: configuration.url, timeoutInterval: configuration.requestTimeout)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("langtools-agent", forHTTPHeaderField: "User-Agent")
            request.setValue(deliveryID, forHTTPHeaderField: Self.deliveryHeader)
            if let runID = result.runID { request.setValue(runID, forHTTPHeaderField: Self.runIDHeader) }
            if let secret = configuration.secret {
                request.setValue(WebhookSignature.sign(body: body, secret: secret, timestamp: now()), forHTTPHeaderField: WebhookSignature.header)
            }

            var retryAfter: TimeInterval?
            do {
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                outcome.statusCode = status
                if (200..<300).contains(status) {
                    outcome.delivered = true
                    outcome.error = nil
                    return outcome
                }
                outcome.error = "Webhook answered HTTP \(status)."
                guard Self.isRetryable(status: status) else { return outcome }
                retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            } catch {
                outcome.error = error.localizedDescription
            }

            guard attempt < configuration.maxAttempts else { break }
            do { try await sleep(configuration.backoff(afterAttempt: attempt, retryAfter: retryAfter)) }
            catch { break }
        }
        return outcome
    }

    static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500..<600).contains(status)
    }
}

/// The `X-LangTools-Signature` header: `t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<body>">`.
public enum WebhookSignature {
    public static let header = "X-LangTools-Signature"

    public static func sign(body: Data, secret: String, timestamp: Date) -> String {
        let t = Int(timestamp.timeIntervalSince1970)
        let mac = HMAC<SHA256>.authenticationCode(for: signedPayload(body: body, timestamp: t), using: SymmetricKey(data: Data(secret.utf8)))
        return "t=\(t),v1=\(Data(mac).map { String(format: "%02x", $0) }.joined())"
    }

    /// True when `header` signs `body` with `secret` and its timestamp is within `tolerance` of `now`.
    public static func verify(body: Data, header: String, secret: String, now: Date = Date(), tolerance: TimeInterval = 300) -> Bool {
        var timestamp: Int?
        var signatures: [Data] = []
        for part in header.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            if pair[0] == "t" { timestamp = Int(pair[1]) }
            else if pair[0] == "v1", let mac = Data(hex: pair[1]) { signatures.append(mac) }
        }
        guard let timestamp, abs(now.timeIntervalSince1970 - TimeInterval(timestamp)) <= tolerance else { return false }
        let key = SymmetricKey(data: Data(secret.utf8))
        let payload = signedPayload(body: body, timestamp: timestamp)
        return signatures.contains { HMAC<SHA256>.isValidAuthenticationCode($0, authenticating: payload, using: key) }
    }

    private static func signedPayload(body: Data, timestamp: Int) -> Data {
        Data("\(timestamp).".utf8) + body
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
