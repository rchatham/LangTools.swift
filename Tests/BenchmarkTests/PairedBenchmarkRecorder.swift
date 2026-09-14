//
//  PairedBenchmarkRecorder.swift
//  BenchmarkTests
//
//  Emits paired benchmark result records deterministically. By default records
//  are printed to stdout for ad-hoc capture. For reproducible results, set
//  `LANGTOOLS_PAIRED_RESULTS_FILE` to a path: each record is appended as one
//  line through a single file write, avoiding interleaving with XCTest progress
//  output on shared stdout (records exceed PIPE_BUF, so concurrent stdout
//  writes are not atomic). See docs/benchmark-capture.md for the capture
//  protocol.
//

import Foundation

enum PairedBenchmarkRecorder {
    private static let lock = NSLock()
    private static var handle: FileHandle?

    static func emit(prefix: String, json: Data) {
        let line = prefix + " " + String(decoding: json, as: UTF8.self) + "\n"
        let data = Data(line.utf8)
        if let path = ProcessInfo.processInfo.environment["LANGTOOLS_PAIRED_RESULTS_FILE"] {
            lock.lock(); defer { lock.unlock() }
            if handle == nil {
                // Create/truncate on first use within this process; subsequent
                // emits append through the kept handle.
                let created = FileManager.default.createFile(atPath: path, contents: nil)
                handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
                if !created || handle == nil {
                    FileHandle.standardError.write(Data("PairedBenchmarkRecorder: cannot open results file \(path)\n".utf8))
                }
            }
            handle?.write(data)
        } else {
            print(line, terminator: "")
        }
    }
}