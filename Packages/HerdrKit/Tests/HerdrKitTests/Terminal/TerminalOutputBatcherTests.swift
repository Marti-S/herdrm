import XCTest
@testable import HerdrKit

final class TerminalOutputBatcherTests: XCTestCase {
    @MainActor
    func testConcurrentLargeAppendsPreserveAdmissionOrderAndStayBounded() async throws {
        let firstDelivery = expectation(description: "first delivery entered")
        let gate = fixtureGate("first output delivery")
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

        let first = fixtureTask("first large append") { await batcher.append(Data([0, 1, 2, 3, 4, 5, 6, 7])) }
        await fulfillment(of: [firstDelivery], timeout: 3)
        let second = fixtureTask("second append admission") { await batcher.append(Data([8, 9])) }

        await Task.yield()
        let queuedBytes = await batcher.queuedByteCount
        XCTAssertLessThanOrEqual(queuedBytes, 4)

        gate.release()
        try await first.value()
        try await second.value()
        try await withFixtureDeadline("finish ordered output") { await batcher.finish() }

        XCTAssertEqual(recorder.combined, Data(0...9))
        XCTAssertTrue(recorder.batches.allSatisfy { $0.count <= 4 })
    }

    @MainActor
    func testBackPressureBlocksOversizedAppendUntilDeliveryDrains() async throws {
        let firstDelivery = expectation(description: "delivery entered")
        firstDelivery.assertForOverFulfill = false
        let gate = fixtureGate("backpressure delivery")
        let completion = CompletionProbe()
        let batcher = TerminalOutputBatcher(
            maximumQueuedBytes: 3,
            immediateDrainBytes: 3
        ) { _ in
            firstDelivery.fulfill()
            await gate.waitOnFirstCall()
        }

        let append = fixtureTask("backpressured append") {
            await batcher.append(Data([0, 1, 2, 3, 4, 5, 6]))
            await completion.markComplete()
        }
        await fulfillment(of: [firstDelivery], timeout: 3)
        await Task.yield()
        let completedBeforeDrain = await completion.value()
        let queuedBytes = await batcher.queuedByteCount
        XCTAssertFalse(completedBeforeDrain)
        XCTAssertLessThanOrEqual(queuedBytes, 3)

        gate.release()
        try await append.value()
        let completedAfterDrain = await completion.value()
        XCTAssertTrue(completedAfterDrain)
        try await withFixtureDeadline("finish backpressured output") { await batcher.finish() }
    }

    @MainActor
    func testFinishWaitsForAcceptedAppendAndIsIdempotent() async throws {
        let firstDelivery = expectation(description: "delivery entered")
        let gate = fixtureGate("finish delivery")
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

        let append = fixtureTask("accepted append") { await batcher.append(Data(0...8)) }
        await fulfillment(of: [firstDelivery], timeout: 3)
        let finish = fixtureTask("finish waiting for append") { await batcher.finish() }
        await Task.yield()

        gate.release()
        try await append.value()
        try await finish.value()
        try await withFixtureDeadline("idempotent finish") { await batcher.finish() }

        XCTAssertEqual(recorder.combined, Data(0...8))
    }

    @MainActor
    func testCancelDiscardsPendingBytesWakesBlockedAppendAndIsIdempotent() async throws {
        let firstDelivery = expectation(description: "delivery entered")
        firstDelivery.assertForOverFulfill = false
        let gate = fixtureGate("cancelled delivery")
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

        let append = fixtureTask("cancelled append") {
            await batcher.append(Data(0...8))
            await completion.markComplete()
        }
        await fulfillment(of: [firstDelivery], timeout: 3)
        let admissionWaiter = fixtureTask("cancelled admission waiter") { await batcher.append(Data([9])) }
        await Task.yield()

        await batcher.cancel()
        try await append.value()
        try await admissionWaiter.value()
        let completedAfterCancel = await completion.value()
        XCTAssertTrue(completedAfterCancel)

        await batcher.cancel()
        try await withFixtureDeadline("append after cancel") { await batcher.append(Data([10])) }
        try await withFixtureDeadline("finish after cancel") { await batcher.finish() }
        gate.release()
        await Task.yield()

        XCTAssertEqual(recorder.combined, Data([0, 1, 2]))
    }

    @MainActor
    func testCancelBeforeScheduledDrainDeliversNothing() async throws {
        let recorder = DeliveryRecorder()
        let batcher = TerminalOutputBatcher(
            maximumQueuedBytes: 8,
            immediateDrainBytes: 8
        ) { recorder.deliver($0) }

        try await withFixtureDeadline("append and cancel before scheduled drain") {
            await batcher.append(Data([1, 2, 3]))
            await batcher.cancel()
        }
        try await withFixtureDeadline("finish before scheduled drain") { await batcher.finish() }
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


private actor CompletionProbe {
    private var isComplete = false
    func markComplete() { isComplete = true }
    func value() -> Bool { isComplete }
}
