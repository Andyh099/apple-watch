import Foundation
import XCTest
@testable import InterpreterCore

private actor SentEvents {
    private(set) var audio: [Data] = []
    private(set) var closed = false
    func append(_ data: Data) { audio.append(data) }
    func close() { closed = true }
}

private actor SendGate {
    var continuation: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    var hasStarted = false
    func wait() async {
        hasStarted = true
        started?.resume()
        started = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForStart() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class AudioUploadSenderTests: XCTestCase {
    // Intentional synchronous stall solely to test isolation from UI work.
    @MainActor private func blockUIActorForTest(_ signal: DispatchSemaphore) -> DispatchTimeoutResult {
        signal.wait(timeout: .now() + 1)
    }

    func testDrainsExactBytesIncludingSilenceBeforeStop() async throws {
        let queue = AudioUploadQueue()
        let frames = (0..<15).map { Data(repeating: UInt8($0), count: 4_800) }
        for frame in frames { queue.enqueue(frame) }
        queue.finish()
        let events = SentEvents()
        try await AudioUploadSender.run(queue: queue, sendAudio: { await events.append($0) },
                                       finishInput: { await events.close() }, onProgress: { _ in })
        let received = await events.audio
        let closed = await events.closed
        XCTAssertEqual(received.map(\.count), [48_000, 24_000])
        XCTAssertEqual(received.reduce(Data(), +), frames.reduce(Data(), +))
        XCTAssertTrue(closed)
    }

    func testCancelWakesIdleSenderWithoutStopCommand() async throws {
        let queue = AudioUploadQueue()
        let events = SentEvents()
        let task = Task.detached {
            try await AudioUploadSender.run(queue: queue, sendAudio: { await events.append($0) },
                                           finishInput: { await events.close() }, onProgress: { _ in })
        }
        queue.cancel()
        try await task.value
        let closed = await events.closed
        let audio = await events.audio
        XCTAssertFalse(closed)
        XCTAssertTrue(audio.isEmpty)
    }

    func testCancellationDuringSendDoesNotSendQueuedAudioOrStop() async throws {
        let queue = AudioUploadQueue()
        queue.enqueue(Data(repeating: 1, count: 4_800))
        let gate = SendGate()
        let events = SentEvents()
        let task = Task.detached {
            try await AudioUploadSender.run(queue: queue, sendAudio: {
                await events.append($0)
                await gate.wait()
            }, finishInput: { await events.close() }, onProgress: { _ in })
        }
        await gate.waitForStart()
        queue.enqueue(Data(repeating: 2, count: 4_800))
        queue.cancel()
        task.cancel()
        await gate.release()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let audio = await events.audio
        let closed = await events.closed
        XCTAssertEqual(audio.count, 1)
        XCTAssertFalse(closed)
    }

    @MainActor
    func testDetachedSenderDrainsWhileUIActorIsBlocked() async throws {
        let queue = AudioUploadQueue()
        queue.enqueue(Data(repeating: 0, count: 4_800))
        queue.finish()
        let finished = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try await AudioUploadSender.run(queue: queue, sendAudio: { _ in },
                                           finishInput: { finished.signal() }, onProgress: { _ in })
        }
        // Deliberately block the UI actor. The old MainActor-inherited sender
        // cannot drain until this wait ends; the detached sender completes.
        let result = blockUIActorForTest(finished)
        XCTAssertEqual(result, .success)
        try await task.value
    }

    func testTransportErrorDoesNotSendStopOrReportSuccess() async {
        enum TestFailure: Error { case transport }
        let queue = AudioUploadQueue()
        queue.enqueue(Data(repeating: 0, count: 4_800))
        queue.finish()
        let events = SentEvents()
        do {
            try await AudioUploadSender.run(queue: queue, sendAudio: { _ in throw TestFailure.transport },
                                           finishInput: { await events.close() }, onProgress: { _ in
                XCTFail("Failed send must not publish success")
            })
            XCTFail("Expected send failure")
        } catch { }
        let closed = await events.closed
        XCTAssertFalse(closed)
        XCTAssertEqual(queue.diagnostics().completedBatches, 0)
    }

    func testDiagnosticsDistinguishCaptureBacklogFromInFlightWait() throws {
        let queue = AudioUploadQueue()
        queue.enqueue(Data(repeating: 1, count: 4_800), now: 0)
        _ = try queue.takeBatch(now: 0.1)
        queue.enqueue(Data(repeating: 0, count: 4_800), now: 0.2)
        let snapshot = queue.diagnostics(now: 1.1)
        XCTAssertEqual(snapshot.pendingMilliseconds, 100)
        XCTAssertEqual(snapshot.inFlightMilliseconds, 100)
        XCTAssertEqual(snapshot.oldestMilliseconds, 1_100)
        XCTAssertEqual(snapshot.sendWaitingMilliseconds, 1_000)
        queue.sent()
        XCTAssertEqual(queue.diagnostics(now: 1.1).completedBatches, 1)
        XCTAssertEqual(queue.diagnostics(now: 1.1).sendWaitingMilliseconds, 0)
    }
}
