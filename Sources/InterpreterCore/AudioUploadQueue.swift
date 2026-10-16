import Foundation

/// Bounded microphone handoff with one serial sender. Merge only audio already
/// waiting; never hold a fresh frame to fill a batch or discard silent samples.
public final class AudioUploadQueue: @unchecked Sendable {
    public enum Failure: Error { case backlog, concurrentSend }
    public enum EnqueueResult { case accepted, closed, overflow, invalidFrame }
    public struct Diagnostics: Sendable {
        public let pendingMilliseconds: Int
        public let inFlightMilliseconds: Int
        public let oldestMilliseconds: Int
        public let sendWaitingMilliseconds: Int
        public let completedBatches: Int
        public let droppedMilliseconds: Int
    }
    public struct Batch: Sendable {
        public let data: Data
        public let backlogMilliseconds: Int
    }

    public let signals: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private struct Frame {
        let data: Data
        let receivedAt: TimeInterval
    }
    private var pending: [Frame] = []
    private var pendingBytes = 0
    private var droppedBytes = 0
    private var inFlight: Frame?
    private var sendStartedAt: TimeInterval?
    private var completedBatches = 0
    private var accepting = true
    private var cancelled = false
    private var failed = false
    private let maxBytes = AudioFrameBuffer.bytesPerSecond * 2
    // Match the relay's existing one-second PCM message limit. Only combine
    // frames already waiting: a fresh frame is still sent immediately. A 300ms
    // ceiling cannot keep up when each serial send completes in ~600ms.
    private let batchBytes = AudioFrameBuffer.bytesPerSecond
    private let frameBytes = AudioFrameBuffer.bytesPerSecond / 10

    /// Drop pending audio older than the keep window. Stale speech is skipped
    /// so a slow uplink degrades into a gap instead of killing the session.
    /// In-flight audio is never touched: its send finishes or fails on its own.
    private func dropStaleLocked(keepingMilliseconds: Int, now: TimeInterval) {
        let cutoff = now - Double(keepingMilliseconds) / 1000.0
        while let first = pending.first, first.receivedAt < cutoff {
            droppedBytes += first.data.count
            pendingBytes -= first.data.count
            pending.removeFirst()
        }
    }

    public init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = stream
        wake = continuation
    }

    @discardableResult
    public func enqueue(_ data: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> EnqueueResult {
        let result: EnqueueResult = lock.withLock {
            guard accepting, !cancelled, !failed else { return .closed }
            guard !data.isEmpty, data.count % 2 == 0, data.count <= frameBytes else { return .invalidFrame }
            let oldest = inFlight?.receivedAt ?? pending.first?.receivedAt ?? now
            if now - oldest >= 2 {
                // Uplink can't keep up: skip the stale audio and stay live.
                dropStaleLocked(keepingMilliseconds: 500, now: now)
            }
            if pendingBytes + (inFlight?.data.count ?? 0) + data.count > maxBytes {
                // Still full (a send is stuck): drop more rather than fail.
                dropStaleLocked(keepingMilliseconds: 250, now: now)
                guard pendingBytes + (inFlight?.data.count ?? 0) + data.count <= maxBytes else { return .overflow }
            }
            pending.append(Frame(data: data, receivedAt: now))
            pendingBytes += data.count
            return .accepted
        }
        if case .accepted = result { wake.yield(()) }
        return result
    }

    public func takeBatch(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Batch? {
        try lock.withLock {
            guard !cancelled else { return nil }
            guard !failed else { throw Failure.backlog }
            guard inFlight == nil else { throw Failure.concurrentSend }
            if let first = pending.first, now - first.receivedAt >= 2 {
                dropStaleLocked(keepingMilliseconds: 500, now: now)
            }
            guard let first = pending.first else { return nil }
            let backlogMilliseconds = pendingBytes * 1_000 / AudioFrameBuffer.bytesPerSecond
            var data = Data()
            while let frame = pending.first, data.count + frame.data.count <= batchBytes {
                data.append(frame.data)
                pendingBytes -= frame.data.count
                pending.removeFirst()
            }
            inFlight = Frame(data: data, receivedAt: first.receivedAt)
            sendStartedAt = now
            return Batch(data: data, backlogMilliseconds: backlogMilliseconds)
        }
    }

    public func sent() {
        lock.withLock {
            if inFlight != nil { completedBatches += 1 }
            inFlight = nil
            sendStartedAt = nil
        }
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Numeric local diagnostics only; never exposes PCM, captions or credentials.
    public func diagnostics(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Diagnostics {
        lock.withLock {
            let oldest = inFlight?.receivedAt ?? pending.first?.receivedAt ?? now
            return Diagnostics(
                pendingMilliseconds: pendingBytes * 1_000 / AudioFrameBuffer.bytesPerSecond,
                inFlightMilliseconds: (inFlight?.data.count ?? 0) * 1_000 / AudioFrameBuffer.bytesPerSecond,
                oldestMilliseconds: max(0, Int((now - oldest) * 1_000)),
                sendWaitingMilliseconds: max(0, Int((now - (sendStartedAt ?? now)) * 1_000)),
                completedBatches: completedBatches,
                droppedMilliseconds: droppedBytes * 1_000 / AudioFrameBuffer.bytesPerSecond)
        }
    }

    /// Keep accepted audio and wake the sender to drain it before the stop command.
    public func finish() {
        lock.withLock { accepting = false }
        wake.yield(())
        wake.finish()
    }

    /// User cancellation, backgrounding and failures must not replay queued audio.
    public func cancel() {
        lock.withLock {
            accepting = false
            cancelled = true
            pending.removeAll()
            pendingBytes = 0
            inFlight = nil
            sendStartedAt = nil
        }
        wake.finish()
    }
}
