import Foundation
import XCTest
@testable import LangToolsHelper

final class PairingCodeRegistryTests: XCTestCase {
    func testGenerateProducesExactCodeFromInjectedEntropy() async throws {
        let registry = PairingCodeRegistry(fillEntropy: { bytes in
            for index in bytes.indices {
                bytes[index] = UInt8(index)
            }
            return true
        })

        let code = try await registry.generate()

        XCTAssertEqual(code, (0..<32).map { String(format: "%02x", $0) }.joined())
    }

    func testSystemEntropyCodeMatches64HexShape() async throws {
        let registry = PairingCodeRegistry()

        let code = try await registry.generate()

        XCTAssertEqual(code.count, 64)
        XCTAssertEqual(code, code.lowercased())
        XCTAssertTrue(code.allSatisfy { $0.isASCII && $0.isHexDigit })
    }

    func testConsumeIsSingleUseAndRejectsReplayAndUnknownCodes() async throws {
        let registry = PairingCodeRegistry(fillEntropy: Self.repeatingEntropy(0xab))
        let code = try await registry.generate()

        let firstConsume = await registry.consume(code)
        let replay = await registry.consume(code)
        let unknown = await registry.consume(String(repeating: "cd", count: 32))

        XCTAssertTrue(firstConsume)
        XCTAssertFalse(replay)
        XCTAssertFalse(unknown)
    }

    func testCodeExpiryPreservesInclusiveTTLBoundary() async throws {
        let clock = TestClock()
        let entropy = EntropySequence(startingAt: 1)
        let registry = PairingCodeRegistry(
            ttl: .seconds(5),
            now: { clock.currentInstant },
            fillEntropy: { bytes in entropy.fill(&bytes) }
        )
        let boundaryCode = try await registry.generate()
        clock.advance(by: .seconds(5))

        let boundaryConsume = await registry.consume(boundaryCode)
        XCTAssertTrue(boundaryConsume)

        let expiredCode = try await registry.generate()
        clock.advance(by: .seconds(5) + .nanoseconds(1))

        let expiredConsume = await registry.consume(expiredCode)
        XCTAssertFalse(expiredConsume)
    }

    func testGeneratePrunesExpiredCodesWithoutRemovingFreshCode() async throws {
        let clock = TestClock()
        let entropy = EntropySequence(startingAt: 1)
        let registry = PairingCodeRegistry(
            ttl: .seconds(5),
            now: { clock.currentInstant },
            fillEntropy: { bytes in entropy.fill(&bytes) }
        )
        let expiredCode = try await registry.generate()
        let initialCount = await registry.pendingCodeCount
        XCTAssertEqual(initialCount, 1)
        clock.advance(by: .seconds(6))

        let freshCode = try await registry.generate()
        let prunedCount = await registry.pendingCodeCount
        let expiredConsume = await registry.consume(expiredCode)
        let freshConsume = await registry.consume(freshCode)

        XCTAssertNotEqual(expiredCode, freshCode)
        XCTAssertEqual(prunedCount, 1)
        XCTAssertFalse(expiredConsume)
        XCTAssertTrue(freshConsume)
    }

    func testRegistriesKeepCodesIsolated() async throws {
        let first = PairingCodeRegistry(fillEntropy: Self.repeatingEntropy(0x2a))
        let second = PairingCodeRegistry(fillEntropy: Self.repeatingEntropy(0x2a))
        let code = try await first.generate()

        let otherRegistryConsume = await second.consume(code)
        let issuingRegistryConsume = await first.consume(code)

        XCTAssertFalse(otherRegistryConsume)
        XCTAssertTrue(issuingRegistryConsume)
    }

    func testAllZeroEntropyProducesConsumableLeadingZeroCode() async throws {
        let registry = PairingCodeRegistry(fillEntropy: Self.repeatingEntropy(0))

        let code = try await registry.generate()

        let consumed = await registry.consume(code)
        XCTAssertEqual(code, String(repeating: "0", count: 64))
        XCTAssertTrue(consumed)
    }

    func testEntropyFailureThrows() async {
        let registry = PairingCodeRegistry(fillEntropy: { _ in false })

        do {
            _ = try await registry.generate()
            XCTFail("Expected entropy generation to fail")
        } catch PairingCodeRegistryError.entropyGenerationFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func repeatingEntropy(_ value: UInt8) -> PairingCodeRegistry.EntropyProvider {
        { bytes in
            bytes = [UInt8](repeating: value, count: bytes.count)
            return true
        }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var currentInstant: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        instant = instant.advanced(by: duration)
    }
}

private final class EntropySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: UInt8

    init(startingAt value: UInt8) {
        nextValue = value
    }

    func fill(_ bytes: inout [UInt8]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        bytes = [UInt8](repeating: nextValue, count: bytes.count)
        nextValue &+= 1
        return true
    }
}
