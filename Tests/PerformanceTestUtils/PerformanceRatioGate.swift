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
//  Per-path ceilings live in the committed `ratios.json` next to this file. Run once with
//  `RECORD_PERF_RATIOS=1` to (re)record ceilings from observed ratios (plus headroom); a
//  normal run reads them and asserts.
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
    ///   - maxRatio: fallback ceiling used only when `key` is absent from `ratios.json` (e.g. first run).
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
        let foundation = Self.steadyStateMedian(foundationBlock, iterations: iterations)
        let custom = Self.steadyStateMedian(customBlock, iterations: iterations)

        guard foundation > 0 else {
            XCTFail("Foundation baseline for \(key) measured 0s — cannot compute a ratio", file: file, line: line)
            return
        }
        let ratio = custom / foundation
        print(String(format: "⏱️ perf-ratio[%@]: custom=%.3fms foundation=%.3fms ratio=%.2f×",
                     key, custom * 1000, foundation * 1000, ratio))

        if ProcessInfo.processInfo.environment["RECORD_PERF_RATIOS"] == "1" {
            PerformanceRatios.record(key: key, observedRatio: ratio)
            print("   📝 recorded ceiling for \(key)")
            return
        }

        let ceiling = PerformanceRatios.ceiling(for: key) ?? maxRatio
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
/// `ratios.json` is stored beside this source file (located via `#filePath`) rather than as a
/// `Bundle.module` resource: record mode must write back to the *committed* file, but bundled
/// resources are read-only copies in the build directory. `#filePath` resolves to the source tree,
/// which is present for `swift test` locally and in CI.
public enum PerformanceRatios {

    static let fileURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("ratios.json")

    /// Headroom applied to an observed ratio when recording, so ordinary run-to-run noise doesn't
    /// trip the gate. A regression has to exceed the observed ratio by more than this to fail.
    static let recordHeadroom: Double = 1.4

    public static func load() -> [String: Double] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return map
    }

    public static func ceiling(for key: String) -> Double? {
        load()[key]
    }

    public static func record(key: String, observedRatio: Double) {
        var map = load()
        map[key] = ((observedRatio * recordHeadroom) * 100).rounded() / 100 // 2-decimal ceiling
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(map) else { return }
        try? data.write(to: fileURL)
    }
}
