import Foundation

/// Run on a detached task, not the UI actor. One send at a time preserves order;
/// the UI callback must not block the drain loop.
public enum AudioUploadSender {
    public struct Progress: Sendable {
        public let batches: Int
        public let batchMilliseconds: Int
        public let backlogMilliseconds: Int
        public let sendMilliseconds: Int
    }

    public static func run(
        queue: AudioUploadQueue,
        sendAudio: @escaping @Sendable (Data) async throws -> Void,
        finishInput: @escaping @Sendable () async throws -> Void,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        var batches = 0
        for await _ in queue.signals {
            try Task.checkCancellation()
            while let batch = try queue.takeBatch() {
                try Task.checkCancellation()
                let started = ProcessInfo.processInfo.systemUptime
                try await sendAudio(batch.data)
                queue.sent()
                try Task.checkCancellation()
                batches += 1
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                // Do not publish UI changes for every audio packet.
                if batches == 1 || batches.isMultiple(of: 25) || elapsed >= 500 {
                    onProgress(Progress(batches: batches,
                                        batchMilliseconds: batch.data.count * 1_000 / AudioFrameBuffer.bytesPerSecond,
                                        backlogMilliseconds: batch.backlogMilliseconds,
                                        sendMilliseconds: elapsed))
                }
            }
        }
        try Task.checkCancellation()
        // cancel() also wakes a sender waiting for input. It must not send stop
        // or replay audio after backgrounding, reset, or server closure.
        guard !queue.isCancelled else { return }
        try await finishInput()
    }
}
