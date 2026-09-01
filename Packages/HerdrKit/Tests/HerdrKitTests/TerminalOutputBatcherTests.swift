import XCTest
@testable import HerdrKit

final class TerminalOutputBatcherTests: XCTestCase {
    @MainActor
    func testConcurrentLargeAppendsPreserveAdmissionOrderAndStayBounded() async {
        let firstDelivery = expectation(description: "first delivery entered")
        let gate = OneShotGate()
        firstDelivery.assertForOverFulfill = false
        let recorder = DeliveryRecorder()
        let batcher = TerminalOutputBatcher(
            maximumQueuedBytes: 4,
            immediateDrainBytes: 4
        ) { data in
            firstDelivery.fulfill()
            await gate.waitOnFirstCall()
            recorder.deliver(data)
        }

        let first = Task { await batcher.append(Data([0, 1, 2, 3, 4, 5, 6, 7])) }
        await fulfillment(of: [firstDelivery])
        let second = Task { await batcher.append(Data([8, 9])) }

        await Task.yield()
        let queuedBytes = await batcher.queuedByteCount
        XCTAssertLessThanOrEqual(queuedBytes, 4)

        await gate.release()
        await first.value
        await second.value
        await batcher.finish()

        XCTAssertEqual(recorder.combined, Data(0...9))
        XCTAssertTrue(recorder.batches.allSatisfy { $0.count <= 4 })
    }

    @MainActor
    func testBackPressureBlocksOversizedAppendUntilDeliveryDrains() async {
        let firstDelivery = expectation(description: "delivery entered")
        firstDelivery.assertForOverFulfill = false
        let gate = OneShotGate()
        let completion = CompletionProbe()
        let batcher = TerminalOutputBatcher(
            maximumQueuedBytes: 3,
            immediateDrainBytes: 3
        ) { _ in
            firstDelivery.fulfill()
            await gate.waitOnFirstCall()
        }

        let append = Task {
            await batcher.append(Data([0, 1, 2, 3, 4, 5, 6]))
            await completion.markComplete()
        }
        await fulfillment(of: [firstDelivery])
        await Task.yield()
        let completedBeforeDrain = await completion.value()
        let queuedBytes = await batcher.queuedByteCount
        XCTAssertFalse(completedBeforeDrain)
        XCTAssertLessThanOrEqual(queuedBytes, 3)

        await gate.release()
        await append.value
        let completedAfterDrain = await completion.value()
        XCTAssertTrue(completedAfterDrain)
        await batcher.finish()
    }

    @MainActor
    func testFinishWaitsForAcceptedAppendAndIsIdempotent() async {
        let firstDelivery = expectation(description: "delivery entered")
        let gate = OneShotGate()
        firstDelivery.assertForOverFulfill = false
        let recorder = DeliveryRecorder()
        let batcher = TerminalOutputBatcher(
            maximumQueuedBytes: 3,
            immediateDrainBytes: 3
        ) { data in
            firstDelivery.fulfill()
            await gate.waitOnFirstCall()
            recorder.deliver(data)
        }

        let append = Task { await batcher.append(Data(0...8)) }
        await fulfillment(of: [firstDelivery])
        let finish = Task { await batcher.finish() }
        await Task.yield()

        await gate.release()
        await append.value
        await finish.value
        await batcher.finish()

        XCTAssertEqual(recorder.combined, Data(0...8))
    }

    @MainActor
    func testCancelDiscardsPendingBytesWakesBlockedAppendAndIsIdempotent() async {
        let firstDelivery = expectation(description: "delivery entered")
        firstDelivery.assertForOverFulfill = false
        let gate = OneShotGate()
        let recorder = DeliveryRecorder()
        let completion = CompletionProbe()
        let batcher = TerminalOutputBatcher(
            maximumQueuedBytes: 3,
            immediateDrainBytes: 3
        ) { data in
            firstDelivery.fulfill()
            recorder.deliver(data)
            await gate.waitOnFirstCall()
        }

        let append = Task {
            await batcher.append(Data(0...8))
            await completion.markComplete()
        }
        await fulfillment(of: [firstDelivery])
        let admissionWaiter = Task { await batcher.append(Data([9])) }
        await Task.yield()

        await batcher.cancel()
        await append.value
        await admissionWaiter.value
        let completedAfterCancel = await completion.value()
        XCTAssertTrue(completedAfterCancel)

        await batcher.cancel()
        await batcher.append(Data([10]))
        await batcher.finish()
        await gate.release()
        await Task.yield()

        XCTAssertEqual(recorder.combined, Data([0, 1, 2]))
    }

    @MainActor
    func testCancelBeforeScheduledDrainDeliversNothing() async {
        let recorder = DeliveryRecorder()
        let batcher = TerminalOutputBatcher(
            maximumQueuedBytes: 8,
            immediateDrainBytes: 8
        ) { recorder.deliver($0) }

        await batcher.append(Data([1, 2, 3]))
        await batcher.cancel()
        await batcher.finish()
        await Task.yield()

        XCTAssertTrue(recorder.batches.isEmpty)
    }
}

@MainActor
private final class DeliveryRecorder {
    private(set) var batches: [Data] = []
    var combined: Data { batches.reduce(into: Data()) { $0.append($1) } }

    func deliver(_ data: Data) {
        batches.append(data)
    }
}

private actor OneShotGate {
    private var shouldWait = true
    private var continuation: CheckedContinuation<Void, Never>?

    func waitOnFirstCall() async {
        guard shouldWait else { return }
        shouldWait = false
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CompletionProbe {
    private var isComplete = false
    func markComplete() { isComplete = true }
    func value() -> Bool { isComplete }
}
