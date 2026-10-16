import Foundation
import XCTest
@testable import InterpreterCore

final class AudioUploadQueueTests: XCTestCase {
    private func frame(_ value: UInt8 = 0) -> Data { Data(repeating: value, count: 4_800) }

    func testFreshAudioSendsImmediatelyAndBacklogMergesWithoutChangingBytes() throws {
        let queue = AudioUploadQueue()
        queue.enqueue(frame(1), now: 0)
        let first = try XCTUnwrap(queue.takeBatch(now: 0))
        XCTAssertEqual(first.data, frame(1))
        queue.enqueue(frame(2), now: 0.1)
        queue.enqueue(frame(0), now: 0.2) // Silence must be retained.
        queue.enqueue(frame(3), now: 0.3)
        queue.enqueue(frame(4), now: 0.4)
        queue.sent()
        let merged = try XCTUnwrap(queue.takeBatch(now: 0.4))
        XCTAssertEqual(merged.data, frame(2) + frame(0) + frame(3) + frame(4))
        XCTAssertEqual(merged.backlogMilliseconds, 400)
        queue.sent()
        XCTAssertNil(try queue.takeBatch(now: 0.4))
    }

    func testPerSendDelayNoLongerForcesOneFrameThroughputLimit() throws {
        // Deterministic transport: 150ms per completed send, input every 100ms.
        // The old one-frame serial sender overflows its 20-frame buffer.
        var oldPending = 0
        var oldCompletion: Int?
        var oldOverflowed = false
        let queue = AudioUploadQueue()
        var completion: Int?
        var transmitted = Data()
        var expected = Data()
        var sends = 0
        for tick in 0...1_200 { // 12 seconds, followed by drain.
            let now = Double(tick) / 100
            if oldCompletion == tick { oldCompletion = nil }
            if completion == tick { queue.sent(); completion = nil }
            if tick < 1_000, tick % 10 == 0 {
                oldPending += 1
                if oldPending > 20 { oldOverflowed = true }
                let bytes = frame(UInt8(tick / 10))
                expected.append(bytes)
                guard case .accepted = queue.enqueue(bytes, now: now) else {
                    return XCTFail("Unexpected backlog at tick \(tick)")
                }
            }
            if oldCompletion == nil, oldPending > 0 { oldPending -= 1; oldCompletion = tick + 15 }
            if completion == nil, let batch = try queue.takeBatch(now: now) {
                XCTAssertLessThanOrEqual(batch.data.count, 48_000)
                transmitted.append(batch.data)
                sends += 1
                completion = tick + 15
            }
        }
        XCTAssertTrue(oldOverflowed)
        XCTAssertEqual(transmitted, expected)
        XCTAssertLessThan(sends, 100)
        queue.cancel()
    }

    func testSustainedSlowSendCatchesUpWithoutDroppingAudio() throws {
        // Delays the 2s age budget absorbs: every accepted byte must be sent.
        for delays in [[600], [750], [900], [200, 600, 800, 450]] {
            let queue = AudioUploadQueue()
            var completion: Int?
            var transmitted = Data()
            var expected = Data()
            var sends = 0
            var largestBatch = 0
            defer { queue.cancel() }
            for nowMs in stride(from: 0, through: 33_000, by: 10) {
                let now = Double(nowMs) / 1_000
                if completion == nowMs { queue.sent(); completion = nil }
                if nowMs < 30_000, nowMs.isMultiple(of: 100) {
                    let bytes = frame(UInt8((nowMs / 100) % 251))
                    expected.append(bytes)
                    guard case .accepted = queue.enqueue(bytes, now: now) else {
                        return XCTFail("Backlog at \(nowMs)ms with send delays \(delays)")
                    }
                }
                if completion == nil, let batch = try queue.takeBatch(now: now) {
                    XCTAssertLessThanOrEqual(batch.data.count, 48_000)
                    transmitted.append(batch.data)
                    largestBatch = max(largestBatch, batch.data.count)
                    completion = nowMs + delays[sends % delays.count]
                    sends += 1
                }
                let snapshot = queue.diagnostics(now: now)
                XCTAssertLessThanOrEqual(snapshot.pendingMilliseconds + snapshot.inFlightMilliseconds, 2_000)
                if snapshot.pendingMilliseconds + snapshot.inFlightMilliseconds > 0 {
                    XCTAssertLessThan(snapshot.oldestMilliseconds, 2_000)
                }
            }
            XCTAssertEqual(transmitted, expected)
            XCTAssertEqual(queue.diagnostics().droppedMilliseconds, 0)
            XCTAssertNil(completion, "All accepted audio must complete before the test ends")
            XCTAssertGreaterThan(largestBatch, 14_400, "Must exceed the old 300ms throughput ceiling")
        }
    }

    func testBriefStallDropsStaleAudioAndStaysLive() throws {
        // A 1200ms stall exceeds the 2s age budget: stale audio is skipped,
        // the queue never overflows, and the session keeps accepting.
        let queue = AudioUploadQueue()
        defer { queue.cancel() }
        var completion: Int?
        var transmitted = Data()
        var overflowed = false
        for nowMs in stride(from: 0, through: 10_000, by: 10) {
            let now = Double(nowMs) / 1_000
            if completion == nowMs { queue.sent(); completion = nil }
            if nowMs.isMultiple(of: 100) {
                if case .overflow = queue.enqueue(frame(), now: now) { overflowed = true }
            }
            if completion == nil, let batch = try queue.takeBatch(now: now) {
                XCTAssertLessThanOrEqual(batch.data.count, 48_000)
                transmitted.append(batch.data)
                completion = nowMs + 1_200
            }
            let snapshot = queue.diagnostics(now: now)
            XCTAssertLessThanOrEqual(snapshot.pendingMilliseconds + snapshot.inFlightMilliseconds, 2_000)
        }
        XCTAssertFalse(overflowed, "Slow transport must degrade into gaps, not stop the session")
        XCTAssertGreaterThan(queue.diagnostics().droppedMilliseconds, 0, "Stale audio must be skipped to stay live")
        XCTAssertGreaterThan(transmitted.count, 0)
    }

    func testLargerBatchIsCappedAtRelayLimitAndDoesNotWaitForMoreAudio() throws {
        let queue = AudioUploadQueue()
        let frames = (0..<15).map { frame(UInt8($0)) }
        for bytes in frames { queue.enqueue(bytes, now: 0) }
        let first = try XCTUnwrap(queue.takeBatch(now: 0.1))
        XCTAssertEqual(first.data, frames.prefix(10).reduce(Data(), +))
        XCTAssertEqual(first.data.count, 48_000)
        queue.sent()
        // Return the already waiting half second immediately; never pad or wait.
        let remainder = try XCTUnwrap(queue.takeBatch(now: 0.1))
        XCTAssertEqual(remainder.data, frames.suffix(5).reduce(Data(), +))
        queue.sent()
        XCTAssertNil(try queue.takeBatch(now: 0.1))
    }

    func testPersistentlySlowTransportDropsStaleInsteadOfStopping() throws {
        // 1100ms sends can never keep up: stale audio is skipped so the
        // session stays live, instead of stopping on overflow.
        let queue = AudioUploadQueue()
        defer { queue.cancel() }
        var completion: Int?
        var overflowed = false
        for nowMs in stride(from: 0, through: 10_000, by: 10) {
            let now = Double(nowMs) / 1_000
            if completion == nowMs { queue.sent(); completion = nil }
            if nowMs.isMultiple(of: 100) {
                if case .overflow = queue.enqueue(frame(), now: now) { overflowed = true }
            }
            if completion == nil, let _ = try queue.takeBatch(now: now) {
                completion = nowMs + 1_100
            }
            let snapshot = queue.diagnostics(now: now)
            XCTAssertLessThanOrEqual(snapshot.pendingMilliseconds + snapshot.inFlightMilliseconds, 2_000)
        }
        XCTAssertFalse(overflowed, "Slow transport must degrade into gaps, not overflow")
        XCTAssertGreaterThan(queue.diagnostics().droppedMilliseconds, 0)
    }

    func testByteBudgetDropsStaleInsteadOfPoisoningQueue() throws {
        let queue = AudioUploadQueue()
        queue.enqueue(frame(), now: 0)
        _ = try queue.takeBatch(now: 0) // 100ms in flight
        for _ in 1..<20 { if case .accepted = queue.enqueue(frame(), now: 0.1) {} else { XCTFail() } }
        // Momentarily over the byte budget: transient overflow, queue stays usable.
        if case .overflow = queue.enqueue(frame(), now: 0.2) {} else { XCTFail("Must bound pending plus in-flight") }
        queue.sent() // in-flight completes, budget frees
        if case .accepted = queue.enqueue(frame(), now: 0.3) {} else { XCTFail("Queue must recover after drain") }
        let batch = try XCTUnwrap(queue.takeBatch(now: 0.4))
        XCTAssertEqual(batch.data.count, 48_000) // capped at the 1s batch limit
    }

    func testStalledSendAndStaleQueuedAudioAreSkippedNotRejected() throws {
        let stalled = AudioUploadQueue()
        stalled.enqueue(frame(), now: 0)
        _ = try stalled.takeBatch(now: 0)
        // A stuck send must not stop the session: new audio is still accepted.
        if case .accepted = stalled.enqueue(frame(), now: 2) {} else { XCTFail("Must stay live during a stalled send") }
        let stale = AudioUploadQueue()
        stale.enqueue(frame(), now: 0)
        // Stale queued audio is skipped, not thrown.
        XCTAssertNil(try stale.takeBatch(now: 2))
        XCTAssertEqual(stale.diagnostics(now: 2).droppedMilliseconds, 100)
    }

    func testFinishDrainsAcceptedAudioButCancelDiscardsIt() throws {
        let queue = AudioUploadQueue()
        queue.enqueue(frame(7), now: 0)
        queue.finish()
        if case .closed = queue.enqueue(frame(), now: 0.1) {} else { XCTFail() }
        XCTAssertEqual(try queue.takeBatch(now: 0.1)?.data, frame(7))
        queue.sent()
        XCTAssertNil(try queue.takeBatch(now: 0.1))
        let cancelled = AudioUploadQueue()
        cancelled.enqueue(frame(), now: 0)
        cancelled.cancel()
        XCTAssertNil(try cancelled.takeBatch(now: 0.1))
        if case .closed = cancelled.enqueue(frame(), now: 0.1) {} else { XCTFail() }
    }

    func testRejectsInvalidPCMAndConcurrentSend() throws {
        let queue = AudioUploadQueue()
        for bytes in [Data(), Data([1]), Data(repeating: 0, count: 4_802)] {
            if case .invalidFrame = queue.enqueue(bytes, now: 0) {} else { XCTFail() }
        }
        queue.enqueue(frame(), now: 0)
        _ = try queue.takeBatch(now: 0)
        XCTAssertThrowsError(try queue.takeBatch(now: 0.1))
    }

    func testCoalescedWakeupsStillDrainAllAudioOnFinish() async throws {
        let queue = AudioUploadQueue()
        for i in 0..<7 { queue.enqueue(frame(UInt8(i))) }
        queue.finish()
        var bytes = Data()
        for await _ in queue.signals {
            while let batch = try queue.takeBatch() {
                bytes.append(batch.data)
                queue.sent()
            }
        }
        XCTAssertEqual(bytes, (0..<7).reduce(into: Data()) { $0.append(frame(UInt8($1))) })
    }

    func testCancelWakesWaitingSenderWithoutAudio() async {
        let queue = AudioUploadQueue()
        let task = Task { () -> Int in
            var signals = 0
            for await _ in queue.signals { signals += 1 }
            return signals
        }
        queue.cancel()
        let signals = await task.value
        XCTAssertEqual(signals, 0)
    }
}
