import AVFAudio
import Foundation
import XCTest
@testable import InterpreterCore

final class StreamingPCMConverterTests: XCTestCase {
    private let rates = [16_000.0, 24_000.0, 44_100.0, 48_000.0]

    private func converted(rate: Double, sizes: [Int], channels: AVAudioChannelCount = 1, interleaved: Bool = false) throws -> Data {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved))
        let converter = try StreamingPCMConverter(inputFormat: format)
        let count = Int(rate * 2)
        var result = Data()
        var offset = 0
        var packet = 0
        while offset < count {
            let length = min(sizes[packet % sizes.count], count - offset)
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)))
            input.frameLength = AVAudioFrameCount(length)
            for channel in 0..<Int(channels) {
                let samples = try XCTUnwrap(input.floatChannelData?[interleaved ? 0 : channel])
                for i in 0..<length {
                    let time = Double(offset + i) / rate
                    // A changing signal exposes missing or repeated portions, not
                    // just sample count. This is synthetic; no microphone used.
                    samples[interleaved ? i * Int(channels) + channel : i] = Float(0.2 * sin(2 * .pi * (440 * time + 37 * time * time)))
                }
            }
            result.append(try converter.convert(input))
            offset += length
            packet += 1
        }
        return result
    }

    func testVariableTapSizesPreserveAllSamplesAndTheirOrder() throws {
        for rate in rates {
            let reference = try converted(rate: rate, sizes: [Int(rate * 2)])
            let streamed = try converted(rate: rate, sizes: [2048, 480, 1024, 4096, 512, 1536, 127])
            XCTAssertGreaterThanOrEqual(streamed.count / 2, 48_000 - 128, "rate=\(rate)")
            XCTAssertLessThanOrEqual(streamed.count / 2, 48_000, "rate=\(rate)")
            XCTAssertEqual(streamed.count, reference.count, "rate=\(rate)")
            XCTAssertTrue(streamed == reference, "Samples missing/repeated/reordered at rate=\(rate)")
        }
    }

    func testSmallAndFixedTapSizesPreserveContinuousAudio() throws {
        for rate in rates {
            let reference = try converted(rate: rate, sizes: [Int(rate * 2)])
            for sizes in [[2048], [1, 7, 63, 128, 511], [4096, 1, 1, 1, 240]] {
                let streamed = try converted(rate: rate, sizes: sizes)
                XCTAssertTrue(streamed == reference, "rate=\(rate), sizes=\(sizes)")
            }
        }
    }

    func testStereoDownmixDoesNotLoseTapBuffers() throws {
        for rate in rates {
            let reference = try converted(rate: rate, sizes: [Int(rate * 2)], channels: 2)
            let streamed = try converted(rate: rate, sizes: [4096, 127, 480, 2048], channels: 2)
            XCTAssertTrue(streamed == reference, "Stereo rate=\(rate)")
        }
    }

    func testInterleavedStereoSlicesRetainAllChannels() throws {
        for rate in rates {
            let reference = try converted(rate: rate, sizes: [Int(rate * 2)], channels: 2, interleaved: true)
            let streamed = try converted(rate: rate, sizes: [4096, 127, 480, 2048], channels: 2, interleaved: true)
            XCTAssertTrue(streamed == reference, "Interleaved rate=\(rate)")
        }
    }

    func testEmptyInputDoesNotEndStreamAndFormatChangesAreRejected() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try StreamingPCMConverter(inputFormat: format)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        XCTAssertTrue(try converter.convert(input).isEmpty)
        input.frameLength = 1600
        input.floatChannelData![0].initialize(repeating: 0, count: 1600)
        let silence = try converter.convert(input)
        XCTAssertGreaterThan(silence.count, 0)
        XCTAssertTrue(silence.allSatisfy { $0 == 0 })
        let wrongFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let wrongInput = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: wrongFormat, frameCapacity: 1))
        XCTAssertThrowsError(try converter.convert(wrongInput))
    }
}
