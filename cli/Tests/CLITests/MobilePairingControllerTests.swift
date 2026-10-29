import XCTest
import AppKit
import Foundation
import Network
import Security
import Darwin
import HelperLink
@testable import HelperCore
@testable import LangToolsHelper

final class MobilePairingControllerTests: XCTestCase {
    @MainActor
    func testDelayedReadyAfterCloseDoesNotGenerateCodeAndSavedDeviceStillConnects() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.removeStore() }
        let code = try await fixture.store.generatePairingCode()
        let pair = try await fixture.store.redeem(.init(code: code.code, name: "Saved Phone"))
        let before = fixture.clock.calls
        let ready = ControllerReadyGate()
        let controller = fixture.controller(ready: ready)
        defer { controller.shutdown() }
        controller.setEnabled(true)
        let port = try await ready.wait()
        XCTAssertTrue(controller.starting, "The ready callback remains held until the exact close interleaving.")
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        ready.release()
        try await waitUntil { !controller.starting }
        XCTAssertTrue(controller.enabled, "Closing only cancels pairing; explicitly enabled saved-device LAN remains on.")
        XCTAssertNil(controller.qrImage)
        XCTAssertNil(controller.expiry)
        XCTAssertNil(controller.activeCode)
        XCTAssertEqual(fixture.clock.calls, before, "Even an undisplayed code must not be generated after close.")
        let response = try await fixture.health(port: port, token: pair.token)
        XCTAssertEqual(response, 200, "A saved phone deliberately retains access after the pairing window closes.")
        controller.shutdown()
        try await waitUntil { !controller.starting }
    }

    @MainActor
    func testCloseDuringIdentityPreparationInvalidatesStartupPairingIntent() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.removeStore() }
        let identityStarted = ControllerSignal()
        let releaseIdentity = ControllerSignal()
        let ready = ControllerReadyGate()
        let identity = fixture.identity
        let controller = fixture.controller(ready: ready, loadIdentity: {
            identityStarted.resolve()
            try await releaseIdentity.wait()
            return identity
        })
        defer { controller.shutdown() }
        controller.setEnabled(true)
        try await identityStarted.wait()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        releaseIdentity.resolve()
        _ = try await ready.wait()
        ready.release()
        try await waitUntil { !controller.starting }
        XCTAssertTrue(controller.enabled)
        XCTAssertNil(controller.qrImage)
        XCTAssertNil(controller.activeCode)
        XCTAssertEqual(fixture.clock.calls, 0)
        controller.shutdown()
        try await waitUntil { !controller.starting }
    }

    @MainActor
    func testCancelBeforeReadyDoesNotGenerateButExplicitRefreshCanPair() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.removeStore() }
        let ready = ControllerReadyGate()
        let controller = fixture.controller(ready: ready)
        defer { controller.shutdown() }
        controller.setEnabled(true)
        _ = try await ready.wait()
        controller.cancelPairing()
        ready.release()
        try await waitUntil { !controller.starting }
        XCTAssertEqual(fixture.clock.calls, 0)
        XCTAssertNil(controller.activeCode)
        controller.refresh()
        try await waitUntil { controller.qrImage != nil }
        let code = try XCTUnwrap(controller.activeCode)
        XCTAssertEqual(fixture.clock.calls, 1)
        let cancellation = controller.cancelPairing()
        await cancellation?.value
        await fixture.assertCodeCancelled(code)
        XCTAssertNil(controller.qrImage)
        XCTAssertNil(controller.expiry)
        controller.shutdown()
        try await waitUntil { !controller.starting }
    }

    @MainActor
    func testQueuedRefreshThenCloseDoesNotResurrectPairing() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.removeStore() }
        let ready = ControllerReadyGate()
        let controller = fixture.controller(ready: ready)
        defer { controller.shutdown() }
        controller.setEnabled(true)
        _ = try await ready.wait()
        ready.release()
        try await waitUntil { controller.qrImage != nil }
        let before = fixture.clock.calls
        // Both calls happen synchronously on MainActor before the refresh Task can execute.
        let refresh = controller.refresh()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        await refresh?.value
        XCTAssertEqual(fixture.clock.calls, before, "A queued refresh cannot establish fresh intent after close.")
        XCTAssertNil(controller.qrImage)
        XCTAssertNil(controller.activeCode)
        controller.shutdown()
        try await waitUntil { !controller.starting }
    }

    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ControllerTestError.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum ControllerTestError: Error { case deadline }

private final class ControllerFixture {
    let identity: MobileTLSIdentity
    let store: MobileDeviceStore
    let host: String
    let directory: URL
    let clock = ControllerClock()

    init() throws {
        guard let interface = MobileLANInterface.available().first else { throw XCTSkip("No private IPv4 interface for listener lifecycle tests.") }
        host = interface.address
        identity = try MobileTLSIdentity.ephemeral()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-controller-\(UUID().uuidString)")
        let clock = self.clock
        store = try MobileDeviceStore(helperID: identity.helperID, fileURL: directory.appendingPathComponent("devices.json"), now: { clock.now() })
    }

    func removeStore() { try? FileManager.default.removeItem(at: directory) }

    @MainActor
    func controller(ready: ControllerReadyGate, loadIdentity: (@Sendable () async throws -> MobileTLSIdentity)? = nil) -> MobilePairingController {
        let identity = self.identity
        let store = self.store
        return MobilePairingController(loadIdentity: loadIdentity ?? { identity }, makeStore: { _ in store },
            makeServer: { host, identity, store, onReady in
                MobileOllamaServer(host: host, port: try controllerFreePort(host), identity: identity, devices: store,
                    onReady: { ready.capture(port: $0, callback: onReady) })
            })
    }

    func health(port: UInt16, token: String) async throws -> Int {
        let pin = ControllerPin(identity: identity)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 3
        let client = URLSession(configuration: configuration, delegate: pin, delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://\(host):\(port)/v1/mobile/health")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await client.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    func assertCodeCancelled(_ code: String) async {
        do {
            _ = try await store.redeem(.init(code: code, name: "Must Not Pair"))
            XCTFail("Cancelled code remained redeemable.")
        } catch { /* Expected: cancelled codes are not redeemable. */ }
    }
}

private final class ControllerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func now() -> Date { lock.withLock { count += 1; return Date() } }
}

private final class ControllerSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    func resolve() { lock.withLock { resolved = true } }
    func wait() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !lock.withLock({ resolved }) {
            guard ContinuousClock.now < deadline else { throw ControllerTestError.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ControllerReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private let captured = ControllerSignal()
    private var value: (UInt16, @Sendable (UInt16) -> Void)?
    func capture(port: UInt16, callback: @escaping @Sendable (UInt16) -> Void) {
        lock.withLock { value = (port, callback) }
        captured.resolve()
    }
    func wait() async throws -> UInt16 {
        try await captured.wait()
        return try lock.withLock { try XCTUnwrap(value?.0) }
    }
    func release() {
        let value = lock.withLock { self.value }
        if let value { value.1(value.0) }
    }
}

private final class ControllerPin: NSObject, URLSessionDelegate {
    private let fingerprint: String
    init(identity: MobileTLSIdentity) { fingerprint = identity.fingerprint }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              digest(SecCertificateCopyData(leaf) as Data) == fingerprint,
              SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private func controllerFreePort(_ host: String) throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw MobileHelperError.invalidInterface }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr(host)
    guard withUnsafePointer(to: &address, { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }) == 0 else { throw MobileHelperError.invalidInterface }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    guard withUnsafeMutablePointer(to: &address, { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }) == 0 else { throw MobileHelperError.invalidInterface }
    return UInt16(bigEndian: address.sin_port)
}
