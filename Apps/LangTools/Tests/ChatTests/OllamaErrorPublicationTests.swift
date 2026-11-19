import Combine
import Foundation
import XCTest
@testable import Chat

@MainActor
final class OllamaErrorPublicationTests: XCTestCase {
    func testClaimsAreServiceOwnedAndExternalAssignmentsInvalidateBeforePublication() throws {
        let first = try ErrorPublicationFixture()
        let second = try ErrorPublicationFixture()
        let claim = first.service.beginErrorPublication(clearError: false)
        XCTAssertFalse(second.service.publishError(PublicationFailure.check, for: claim))
        XCTAssertTrue(first.service.isCurrentErrorPublication(claim))
        var observedInvalidation = false
        let subscription = first.service.$error.dropFirst().sink { _ in
            observedInvalidation = !first.service.isCurrentErrorPublication(claim)
        }
        first.service.error = PublicationFailure.external
        XCTAssertTrue(observedInvalidation)
        XCTAssertFalse(first.service.publishError(nil, for: claim))
        let clearClaim = first.service.beginErrorPublication(clearError: false)
        var clearInvalidatedBeforePublication = false
        let clearSubscription = first.service.$error.dropFirst().sink { _ in
            clearInvalidatedBeforePublication = !first.service.isCurrentErrorPublication(clearClaim)
        }
        first.service.error = nil
        XCTAssertTrue(clearInvalidatedBeforePublication)
        XCTAssertFalse(first.service.publishError(PublicationFailure.check, for: clearClaim))
        withExtendedLifetime((subscription, clearSubscription)) {}
    }

    func testInternalPublicationKeepsClaimButNestedExternalAssignmentInvalidatesIt() throws {
        let fixture = try ErrorPublicationFixture()
        let claim = fixture.service.beginErrorPublication(clearError: false)
        XCTAssertTrue(fixture.service.publishError(PublicationFailure.check, for: claim))
        XCTAssertTrue(fixture.service.isCurrentErrorPublication(claim))
        var nested = false
        let subscription = fixture.service.$error.dropFirst().sink { _ in
            guard !nested else { return }
            nested = true
            fixture.service.error = PublicationFailure.external
        }
        XCTAssertTrue(fixture.service.publishError(PublicationFailure.check, for: claim))
        XCTAssertTrue(nested)
        XCTAssertEqual(fixture.service.error as? PublicationFailure, .external)
        XCTAssertFalse(fixture.service.isCurrentErrorPublication(claim))
        XCTAssertFalse(fixture.service.publishError(PublicationFailure.check, for: claim))
        withExtendedLifetime(subscription) {}
    }

    func testReentrantNewClaimSurvivesOldPublicationAndBeginClear() throws {
        let fixture = try ErrorPublicationFixture()
        var newer: OllamaService.ErrorPublicationClaim?
        var nested = false
        let subscription = fixture.service.$error.dropFirst().sink { _ in
            guard !nested else { return }
            nested = true
            newer = fixture.service.beginErrorPublication(clearError: false)
        }
        let old = fixture.service.beginErrorPublication()
        let current = try XCTUnwrap(newer)
        XCTAssertFalse(fixture.service.isCurrentErrorPublication(old))
        XCTAssertTrue(fixture.service.isCurrentErrorPublication(current))
        XCTAssertFalse(fixture.service.publishError(PublicationFailure.check, for: old))
        XCTAssertTrue(fixture.service.publishError(PublicationFailure.check, for: current))
        withExtendedLifetime(subscription) {}
    }

    func testReentrantClaimedPublicationWinsStoredValueAndNextExternalClearInvalidates() throws {
        let fixture = try ErrorPublicationFixture()
        let old = fixture.service.beginErrorPublication(clearError: false)
        var newer: OllamaService.ErrorPublicationClaim?
        var nested = false
        let subscription = fixture.service.$error.dropFirst().sink { _ in
            guard !nested else { return }
            nested = true
            let claim = fixture.service.beginErrorPublication(clearError: false)
            newer = claim
            XCTAssertTrue(fixture.service.publishError(PublicationFailure.external, for: claim))
        }
        XCTAssertTrue(fixture.service.publishError(PublicationFailure.check, for: old))
        let current = try XCTUnwrap(newer)
        XCTAssertFalse(fixture.service.isCurrentErrorPublication(old))
        XCTAssertTrue(fixture.service.isCurrentErrorPublication(current))
        XCTAssertEqual(fixture.service.error as? PublicationFailure, .external)
        fixture.service.error = nil
        XCTAssertFalse(fixture.service.isCurrentErrorPublication(current))
        XCTAssertNil(fixture.service.error)
        withExtendedLifetime(subscription) {}
    }

    func testObjectWillChangeReentrancyPreservesExternalClearAndInvalidatesBeforeNotification() throws {
        let fixture = try ErrorPublicationFixture()
        let claim = fixture.service.beginErrorPublication(clearError: false)
        var nested = false
        let subscription = fixture.service.objectWillChange.sink {
            guard !nested else { return }
            nested = true
            XCTAssertFalse(fixture.service.isCurrentErrorPublication(claim))
            fixture.service.error = nil
        }
        fixture.service.error = PublicationFailure.external
        XCTAssertTrue(nested)
        XCTAssertNil(fixture.service.error)
        XCTAssertFalse(fixture.service.publishError(PublicationFailure.check, for: claim))
        withExtendedLifetime(subscription) {}
    }

    func testOldRefreshFailureCannotPublishWhileNewerSuccessfulCheckIsHeld() async throws {
        try await verifyOldRefreshVersusCheck(refreshSucceeds: false)
    }

    func testOldRefreshSuccessCannotClearNewerFailedCheckAndStillStoresModels() async throws {
        try await verifyOldRefreshVersusCheck(refreshSucceeds: true)
    }

    private func verifyOldRefreshVersusCheck(refreshSucceeds: Bool) async throws {
        let fixture = try ErrorPublicationFixture()
        let tags = fixture.gate.expect("/api/tags")
        fixture.service.refreshModels()
        await fulfillment(of: [tags], timeout: 2)
        let version = fixture.gate.expect("/api/version")
        let claim = fixture.service.beginErrorPublication()
        let check = fixture.check(claim: claim)
        await fulfillment(of: [version], timeout: 2)
        let finished = fixture.finishedLoading()
        fixture.gate.finish("/api/tags", succeeds: refreshSucceeds)
        await fulfillment(of: [finished.expectation], timeout: 2)
        XCTAssertTrue(fixture.service.isCurrentErrorPublication(claim))
        XCTAssertNil(fixture.service.error)
        XCTAssertFalse(fixture.service.isLoading)
        if refreshSucceeds { fixture.assertModels() }
        fixture.gate.finish("/api/version", succeeds: !refreshSucceeds)
        let accepted = await check.value
        XCTAssertTrue(accepted)
        if refreshSucceeds { XCTAssertNotNil(fixture.service.error) }
        else { XCTAssertNil(fixture.service.error) }
        withExtendedLifetime(finished.subscription) {}
        XCTAssertEqual(fixture.gate.unknownRequests, [])
    }

    func testExternalErrorAndClearSupersedeHeldRefreshAndCheckInBothPolarities() async throws {
        for refreshSucceeds in [false, true] {
            for clear in [false, true] {
                let fixture = try ErrorPublicationFixture()
                let tags = fixture.gate.expect("/api/tags")
                fixture.service.refreshModels()
                await fulfillment(of: [tags], timeout: 2)
                let version = fixture.gate.expect("/api/version")
                let claim = fixture.service.beginErrorPublication()
                let check = fixture.check(claim: claim)
                await fulfillment(of: [version], timeout: 2)
                fixture.service.error = clear ? nil : PublicationFailure.external
                XCTAssertFalse(fixture.service.isCurrentErrorPublication(claim))
                let finished = fixture.finishedLoading()
                fixture.gate.finish("/api/tags", succeeds: refreshSucceeds)
                await fulfillment(of: [finished.expectation], timeout: 2)
                fixture.gate.finish("/api/version", succeeds: !refreshSucceeds)
                let accepted = await check.value
                XCTAssertFalse(accepted)
                XCTAssertEqual(fixture.service.error as? PublicationFailure, clear ? nil : .external)
                if refreshSucceeds { fixture.assertModels() }
                XCTAssertFalse(fixture.service.isLoading)
                withExtendedLifetime(finished.subscription) {}
                XCTAssertEqual(fixture.gate.unknownRequests, [])
            }
        }
    }

    func testNewerRefreshSupersedesHeldCheckInBothPolarities() async throws {
        for refreshSucceeds in [false, true] {
            let fixture = try ErrorPublicationFixture()
            let version = fixture.gate.expect("/api/version")
            let claim = fixture.service.beginErrorPublication()
            let check = fixture.check(claim: claim)
            await fulfillment(of: [version], timeout: 2)
            let tags = fixture.gate.expect("/api/tags")
            fixture.service.refreshModels()
            await fulfillment(of: [tags], timeout: 2)
            XCTAssertFalse(fixture.service.isCurrentErrorPublication(claim))
            fixture.gate.finish("/api/version", succeeds: !refreshSucceeds)
            let accepted = await check.value
            XCTAssertFalse(accepted)
            let finished = fixture.finishedLoading()
            fixture.gate.finish("/api/tags", succeeds: refreshSucceeds)
            await fulfillment(of: [finished.expectation], timeout: 2)
            XCTAssertEqual(fixture.service.error == nil, refreshSucceeds)
            if refreshSucceeds { fixture.assertModels() }
            withExtendedLifetime(finished.subscription) {}
        }
    }

    func testInvalidationAndGraphsAreIndependent() throws {
        let first = try ErrorPublicationFixture()
        let second = try ErrorPublicationFixture()
        let firstClaim = first.service.beginErrorPublication(clearError: false)
        let secondClaim = second.service.beginErrorPublication(clearError: false)
        first.service.invalidateErrorPublications()
        XCTAssertFalse(first.service.publishError(PublicationFailure.check, for: firstClaim))
        XCTAssertTrue(second.service.publishError(PublicationFailure.check, for: secondClaim))
        XCTAssertNil(first.service.error)
        XCTAssertEqual(second.service.error as? PublicationFailure, .check)
    }

    func testEndpointAndTransportChangesInvalidateClaimsAndRetainRefreshBehavior() async throws {
        for updateEndpoint in [false, true] {
            let fixture = try ErrorPublicationFixture()
            let claim = fixture.service.beginErrorPublication(clearError: false)
            let tags = fixture.gate.expect("/api/tags")
            if updateEndpoint {
                _ = try fixture.service.updateEndpoint("http://\(fixture.gate.host):11435")
            } else {
                fixture.service.transportDidChange()
            }
            XCTAssertFalse(fixture.service.isCurrentErrorPublication(claim))
            await fulfillment(of: [tags], timeout: 2)
            let finished = fixture.finishedLoading()
            fixture.gate.finish("/api/tags", succeeds: true)
            await fulfillment(of: [finished.expectation], timeout: 2)
            fixture.assertModels()
            XCTAssertNil(fixture.service.error)
            withExtendedLifetime(finished.subscription) {}
        }
    }

    func testCurrentSuccessfulRefreshExplicitlyPublishesNilAtCompletion() async throws {
        let fixture = try ErrorPublicationFixture()
        var publications = 0
        let subscription = fixture.service.$error.dropFirst().sink { _ in publications += 1 }
        let tags = fixture.gate.expect("/api/tags")
        fixture.service.refreshModels()
        await fulfillment(of: [tags], timeout: 2)
        XCTAssertEqual(publications, 1)
        let finished = fixture.finishedLoading()
        fixture.gate.finish("/api/tags", succeeds: true)
        await fulfillment(of: [finished.expectation], timeout: 2)
        XCTAssertEqual(publications, 2)
        fixture.assertModels()
        withExtendedLifetime((subscription, finished.subscription)) {}
    }
}

private enum PublicationFailure: Error { case check, external }

@MainActor
private final class ErrorPublicationFixture {
    let access: AccessPromptFixture
    let gate = PublicationRequestGate()
    let session: URLSession
    let service: OllamaService

    init() throws {
        access = try AccessPromptFixture()
        _ = try access.configuration.update("http://\(gate.host):11434")
        PublicationURLProtocol.register(gate)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublicationURLProtocol.self]
        session = URLSession(configuration: configuration)
        service = OllamaService(endpointConfiguration: access.configuration, session: session,
            providerAccessManager: access.manager)
    }

    deinit {
        session.invalidateAndCancel()
        PublicationURLProtocol.unregister(gate)
    }

    func check(claim: OllamaService.ErrorPublicationClaim) -> Task<Bool, Never> {
        Task {
            do {
                try await service.checkConnection()
                return service.publishError(nil, for: claim)
            } catch {
                return service.publishError(error, for: claim)
            }
        }
    }

    func finishedLoading() -> (expectation: XCTestExpectation, subscription: AnyCancellable) {
        let expectation = XCTestExpectation(description: "current refresh finishes")
        let subscription = service.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in expectation.fulfill() }
        return (expectation, subscription)
    }

    func assertModels(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(service.availableModels.map(\.rawValue), ["fixture-model"], file: file, line: line)
        XCTAssertEqual(access.configuration.cachedModels().map(\.rawValue), ["fixture-model"], file: file, line: line)
        XCTAssertTrue(service.runningModels.isEmpty, file: file, line: line)
    }
}

/// All URLs are intercepted. Only this fixture's exact host and three known paths
/// have responses; tags/version are held until explicitly released by the test.
private final class PublicationRequestGate: @unchecked Sendable {
    let host = "publication-\(UUID().uuidString.lowercased()).invalid"
    private let lock = NSLock()
    private var pending: [String: [PublicationURLProtocol]] = [:]
    private var expectations: [String: XCTestExpectation] = [:]
    private var unknown: [String] = []
    var unknownRequests: [String] { lock.lock(); defer { lock.unlock() }; return unknown }

    func expect(_ path: String) -> XCTestExpectation {
        lock.lock(); defer { lock.unlock() }
        let expectation = XCTestExpectation(description: "request \(path)")
        expectations[path] = expectation
        return expectation
    }

    func receive(_ transport: PublicationURLProtocol) {
        guard let url = transport.request.url,
              url.host == host, ["/api/tags", "/api/ps", "/api/version"].contains(url.path) else {
            lock.lock(); unknown.append(transport.request.url?.absoluteString ?? "nil"); lock.unlock()
            transport.fail()
            return
        }
        if url.path == "/api/ps" { transport.respond("{\"models\":[]}"); return }
        lock.lock()
        pending[url.path, default: []].append(transport)
        let expectation = expectations.removeValue(forKey: url.path)
        lock.unlock()
        expectation?.fulfill()
    }

    func finish(_ path: String, succeeds: Bool) {
        lock.lock()
        let transport = pending[path]?.isEmpty == false ? pending[path]?.removeFirst() : nil
        lock.unlock()
        guard let transport else { XCTFail("No pending \(path)"); return }
        if !succeeds { transport.fail(); return }
        if path == "/api/version" { transport.respond("{\"version\":\"fixture\"}") }
        else {
            transport.respond("""
                {"models":[{"name":"fixture-model","modified_at":"fixture","size":1,"digest":"fixture","details":{}}]}
                """)
        }
    }
}

private final class PublicationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var gates: [String: PublicationRequestGate] = [:]
    static func register(_ gate: PublicationRequestGate) { lock.lock(); defer { lock.unlock() }; gates[gate.host] = gate }
    static func unregister(_ gate: PublicationRequestGate) { lock.lock(); defer { lock.unlock() }; gates.removeValue(forKey: gate.host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let gate = request.url?.host.flatMap { Self.gates[$0] }
        Self.lock.unlock()
        guard let gate else { fail(); return }
        gate.receive(self)
    }
    func respond(_ json: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]) else { fail(); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    override func stopLoading() {}
}
