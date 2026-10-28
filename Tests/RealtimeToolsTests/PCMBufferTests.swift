//
//  PCMBufferTests.swift
//  LangTools
//

#if canImport(Speech)
import XCTest
import AVFoundation
@testable import RealtimeTools

final class PCMBufferTests: XCTestCase {

    /// Regression test: for odd-length input the conversion used to copy
    /// data.count bytes into a buffer sized for data.count / 2 samples,
    /// writing one byte past the end.
    func testOddLengthInputDropsTrailingByte() throws {
        // Little-endian Int16 samples 0x0201 and 0x0403, then half a sample.
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        let buffer = try XCTUnwrap(makePCM16MonoBuffer(from: data, sampleRate: 16000))

        XCTAssertEqual(buffer.frameLength, 2)
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        XCTAssertEqual(samples[0], 0x0201)
        XCTAssertEqual(samples[1], 0x0403)
    }

    func testEvenLengthInputKeepsEverySample() throws {
        let data = Data([0x10, 0x00, 0xFF, 0x7F])

        let buffer = try XCTUnwrap(makePCM16MonoBuffer(from: data, sampleRate: 24000))

        XCTAssertEqual(buffer.frameLength, 2)
        XCTAssertEqual(buffer.format.sampleRate, 24000)
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        XCTAssertEqual(samples[0], 0x0010)
        XCTAssertEqual(samples[1], Int16.max)
    }
}
#endif
