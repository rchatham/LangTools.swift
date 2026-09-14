//
//  PerformanceRatioGate.swift
//  LangTools
//
//  A CLI-/CI-friendly performance gate for `swift test`. Native XCTest `.xcbaseline`
//  files require an `.xcodeproj`/Xcode (unavailable in this pure SwiftPM package), and
//  absolute wall-clock thresholds are machine-dependent (CI runners are slower and noisier
//  than a dev laptop) so they flake.
//
//  Instead we gate each hot custom path against a Foundation baseline (`JSONSerialization`)
//  of the *same* payload, measured in the same run. Dividing the two normalizes out machine
//  speed, so the assertion is a stable *ratio* — an invariant of the code, not the hardware.
//  A regression shows up as "combining went from 3× to 6× raw-parse cost", which is a
//  statement about the change, not the machine it ran on.
//
//  Per-path ceilings live in the committed `ratios.json` under Tests/PerformanceTestUtils.
//  Run once with `RECORD_PERF_RATIOS=1` to (re)record ceilings from observed ratios
//  (plus headroom); a normal run reads them and asserts.
//

import XCTest
import Foundation

public extension XCTestCase {

    /// Asserts that `customBlock` stays within an allowed multiple of `foundationBlock`, using the
    /// Foundation baseline to cancel out machine speed so the gate is stable across laptops and CI.
    ///
    /// - Parameters:
    ///   - foundationBlock: a Foundation baseline (e.g. `JSONSerialization`) over the *same* payload,
    ///     run the same number of atomic operations as `customBlock` so the ratio is per-operation.
    ///   - customBlock: the LangTools path under test.
    ///   - maxRatio: retained for call-site compatibility; never used as a fallback. Normal runs
    ///     require a valid committed ceiling. Bootstrap explicitly with `RECORD_PERF_RATIOS=1`.
    ///   - key: stable identifier, also the `ratios.json` key (e.g. `"OpenAI.responseCombining"`).
    ///   - iterations: number of timed samples; the steady-state median is used (cold run discarded).
    ///
    /// Set `RECORD_PERF_RATIOS=1` to write the observed ratio (with headroom) back to `ratios.json`
    /// instead of asserting.
    func assertWithinRatio(
        of foundationBlock: () -> Void,
        _ customBlock: () -> Void,
        maxRatio: Double,
        key: String,
        iterations: Int = 7,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let recording = ProcessInfo.processInfo.environment["RECORD_PERF_RATIOS"] == "1"
        let ceiling: Double?
        do {
            if recording {
                ceiling = nil
            } else {
                ceiling = try PerformanceRatios.ceiling(for: key)
            }
        } catch {
            XCTFail("Cannot load performance ceiling for \(key): \(error). Fix \(PerformanceRatios.fileURL.path); bootstrap only with RECORD_PERF_RATIOS=1", file: file, line: line)
            return
        }
        guard iterations > 0 else {
            XCTFail("Performance sample count must be positive", file: file, line: line)
            return
        }
        let foundation = Self.steadyStateMedian(foundationBlock, iterations: iterations)
        let custom = Self.steadyStateMedian(customBlock, iterations: iterations)

        guard foundation > 0 else {
            XCTFail("Foundation baseline for \(key) measured 0s — cannot compute a ratio", file: file, line: line)
            return
        }
        let ratio = custom / foundation
        print(String(format: "⏱️ perf-ratio[%@]: custom=%.3fms foundation=%.3fms ratio=%.2f×",
                     key, custom * 1000, foundation * 1000, ratio))

        if recording {
            do {
                try PerformanceRatios.record(key: key, observedRatio: ratio)
                print("   📝 recorded ceiling for \(key)")
            } catch {
                XCTFail("Failed to record performance ratio for \(key): \(error)", file: file, line: line)
            }
            return
        }

        guard let ceiling else {
            XCTFail("Missing performance ceiling for \(key)", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(
            ratio, ceiling,
            "\(key) is \(String(format: "%.2f", ratio))× the Foundation baseline, exceeding the ceiling of \(String(format: "%.2f", ceiling))× (see ratios.json; re-record with RECORD_PERF_RATIOS=1 if this is an intended change)",
            file: file, line: line)
    }

    /// Runs `block` `iterations` times and returns the median wall-clock seconds. A warm-up run is
    /// discarded so first-touch page faults / cache misses don't skew the measurement, and the median
    /// (not the mean) is used so an occasional scheduler hiccup doesn't inflate the result.
    private static func steadyStateMedian(_ block: () -> Void, iterations: Int) -> TimeInterval {
        block() // warm-up, discarded
        var samples: [TimeInterval] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now()
            block()
            let end = DispatchTime.now()
            samples.append(Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000)
        }
        samples.sort()
        return samples[samples.count / 2]
    }
}

/// Loads and records the committed per-path ratio ceilings.
///
/// `ratios.json` is stored in `Tests/PerformanceTestUtils` and located via a `#filePath`-relative
/// source-tree path rather than as a `Bundle.module` resource: record mode must write back to the
/// *committed* file, but bundled resources are read-only copies in the build directory.
public enum PerformanceRatios {

    public static let fileURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("PerformanceTestUtils")
        .appendingPathComponent("ratios.json")

    /// Headroom applied to an observed ratio when recording, so ordinary run-to-run noise doesn't
    /// trip the gate. A regression has to exceed the observed ratio by more than this to fail.
    static let recordHeadroom: Double = 1.4

    enum ConfigurationError: Error, Equatable {
        case missingKey(String)
        case invalidRatio(String)
    }

    /// Normal reads fail closed, including missing files. URL injection isolates regression tests.
    public static func load(from url: URL = fileURL) throws -> [String: Double] {
        let data = try Data(contentsOf: url)
        let map = try JSONDecoder().decode([String: Double].self, from: data)
        for (key, value) in map where !value.isFinite || value <= 0 {
            throw ConfigurationError.invalidRatio(key)
        }
        return map
    }

    public static func ceiling(for key: String, from url: URL = fileURL) throws -> Double {
        guard let ceiling = try load(from: url)[key] else {
            throw ConfigurationError.missingKey(key)
        }
        return ceiling
    }

    /// Explicit recording alone may bootstrap a missing file/key. Existing corrupt or unreadable
    /// configuration still throws; failed writes propagate rather than claiming a saved ceiling.
    public static func record(key: String, observedRatio: Double, to url: URL = fileURL) throws {
        let ceiling = ((observedRatio * recordHeadroom) * 100).rounded() / 100
        guard observedRatio.isFinite, observedRatio > 0, ceiling.isFinite, ceiling > 0 else {
            throw ConfigurationError.invalidRatio(key)
        }
        var map: [String: Double] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            map = try load(from: url)
        }
        map[key] = ceiling
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(map)
        // .atomic so an interrupted run can't leave a truncated ratios.json, which load()
        // would then reject and fail every gate.
        try data.write(to: url, options: .atomic)
    }
}
