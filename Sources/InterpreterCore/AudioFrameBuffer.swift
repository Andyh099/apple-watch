import Foundation

/// 24 kHz, mono, signed PCM16 little endian. Never removes silent frames.
public struct AudioFrameBuffer: Sendable {
    public static let sampleRate = 24_000
    public static let bytesPerSecond = sampleRate * 2
    public let frameBytes: Int
    private var pending = Data()

    public init(milliseconds: Int = 100) {
        precondition(milliseconds > 0 && milliseconds <= 1_000)
        frameBytes = Self.bytesPerSecond * milliseconds / 1_000
    }

    public mutating func append(_ bytes: Data) -> [Data] {
        pending.append(bytes)
        var frames: [Data] = []
        while pending.count >= frameBytes {
            frames.append(Data(pending.prefix(frameBytes)))
            pending.removeFirst(frameBytes)
        }
        return frames
    }

    /// Only complete samples may be sent; retain a trailing byte until completed.
    public mutating func flush() -> Data {
        let length = pending.count - pending.count % 2
        let result = Data(pending.prefix(length))
        pending.removeFirst(length)
        return result
    }

    public mutating func reset() { pending.removeAll(keepingCapacity: true) }
}
