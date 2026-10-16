import AVFAudio
import Foundation

/// Serial-use converter for a continuous microphone stream. An output buffer can
/// fill from previously buffered input without requesting the current tap buffer.
/// Drain until inputRanDry so that every tap buffer is consumed exactly once.
public final class StreamingPCMConverter {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    public init(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                  sampleRate: 24_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ConversionError.invalidFormat
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    public func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        guard input.format == inputFormat else { throw ConversionError.invalidFormat }
        guard input.frameLength > 0 else { return Data() }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 24_000 / inputFormat.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw ConversionError.allocationFailed
        }
        var offset: AVAudioFrameCount = 0
        var inputFailed = false
        var bytes = Data()
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, state in
                guard offset < input.frameLength else { state.pointee = .noDataNow; return nil }
                let length = min(requested, input.frameLength - offset)
                guard length > 0 else {
                    inputFailed = true
                    state.pointee = .noDataNow
                    return nil
                }
                let chunk: AVAudioPCMBuffer
                if offset == 0, length == input.frameLength {
                    chunk = input
                } else {
                    guard let slice = AVAudioPCMBuffer(pcmFormat: self.inputFormat, frameCapacity: length) else {
                        inputFailed = true
                        state.pointee = .noDataNow
                        return nil
                    }
                    slice.frameLength = length
                    let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
                    let destination = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
                    let stride = Int(self.inputFormat.streamDescription.pointee.mBytesPerFrame)
                    for channel in 0..<source.count {
                        guard let from = source[channel].mData, let to = destination[channel].mData else {
                            inputFailed = true
                            state.pointee = .noDataNow
                            return nil
                        }
                        to.copyMemory(from: from.advanced(by: Int(offset) * stride), byteCount: Int(length) * stride)
                    }
                    chunk = slice
                }
                offset += length
                state.pointee = .haveData
                return chunk
            }
            guard error == nil, !inputFailed else { throw ConversionError.conversionFailed }
            if output.frameLength > 0 {
                guard let samples = output.int16ChannelData?[0] else { throw ConversionError.conversionFailed }
                bytes.append(Data(bytes: samples, count: Int(output.frameLength) * 2))
            }
            switch status {
            case .inputRanDry:
                guard offset == input.frameLength else { throw ConversionError.conversionFailed }
                return bytes
            case .haveData:
                // Do not discard the tap buffer just because output was produced.
                guard output.frameLength > 0 else { throw ConversionError.conversionFailed }
            case .error, .endOfStream:
                throw ConversionError.conversionFailed
            @unknown default:
                throw ConversionError.conversionFailed
            }
        }
    }

    public enum ConversionError: Error {
        case invalidFormat, allocationFailed, conversionFailed
    }
}
