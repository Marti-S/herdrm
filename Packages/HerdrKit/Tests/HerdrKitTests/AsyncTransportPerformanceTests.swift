import Foundation
import XCTest
@testable import HerdrKit

private enum PerformanceTestError: Error { case timeout, failed }

private func eventually(_ condition: @escaping () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw PerformanceTestError.timeout }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private actor PerformanceGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private actor PerformanceRecorder {
    var bytes: [Data] = []
    var instants: [ContinuousClock.Instant] = []
    func record(_ data: Data = Data()) { bytes.append(data); instants.append(.now) }
    var count: Int { bytes.count }
}

final class AsyncTransportPerformanceTests: XCTestCase {
    func testWriterBoundsIncludeInflightBytes() async throws {
        let gate = PerformanceGate(), recorder = PerformanceRecorder()
        let writer = BoundedAsyncWriter(maximumBytes: 4) { data in
            await recorder.record(data)
            await gate.wait()
        }
        let first = Task { try await writer.send(Data([1, 2, 3, 4])) }
        try await eventually { await recorder.count == 1 }
        do { try await writer.send(Data([5])); XCTFail("Expected a bounded admission failure") }
        catch { XCTAssertEqual(error as? BoundedAsyncWriter.Failure, .overloaded) }
        await gate.open()
        try await first.value
        let remaining = await writer.queuedByteCount
        XCTAssertEqual(remaining, 0)
        await writer.close()
    }

    func testWriterCancellationPreservesOtherQueuedWrites() async throws {
        let gate = PerformanceGate(), recorder = PerformanceRecorder()
        let writer = BoundedAsyncWriter { data in await recorder.record(data); await gate.wait() }
        let first = Task { try await writer.send(Data([1])) }
        try await eventually { await recorder.count == 1 }
        let cancelled = Task { try await writer.send(Data([2])) }
        try await eventually { await writer.queuedByteCount == 2 }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let third = Task { try await writer.send(Data([3])) }
        try await eventually { await writer.queuedByteCount == 2 }
        await gate.open()
        try await first.value
        try await third.value
        let bytes = await recorder.bytes
        XCTAssertEqual(bytes, [Data([1]), Data([3])])
        await writer.close()
    }

    func testWriterCloseResolvesInflightAndQueuedWaitersExactlyOnce() async throws {
        let gate = PerformanceGate(), recorder = PerformanceRecorder()
        let writer = BoundedAsyncWriter { data in await recorder.record(data); await gate.wait() }
        let first = Task { try await writer.send(Data([1])) }
        try await eventually { await recorder.count == 1 }
        let second = Task { try await writer.send(Data([2])) }
        try await eventually { await writer.queuedByteCount == 2 }
        await writer.close()
        await gate.open()
        for task in [first, second] {
            do { try await task.value; XCTFail("Expected closure") }
            catch { XCTAssertEqual(error as? BoundedAsyncWriter.Failure, .closed) }
        }
        await writer.close()
        let remaining = await writer.queuedByteCount
        XCTAssertEqual(remaining, 0)
    }

    func testWriterFailureIsPropagatedWithoutRetry() async throws {
        let recorder = PerformanceRecorder()
        let writer = BoundedAsyncWriter { data in
            await recorder.record(data)
            throw PerformanceTestError.failed
        }
        for _ in 0..<2 {
            do { try await writer.send(Data([1])); XCTFail("Expected failure") } catch {}
        }
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testMultiplexerCorrelatesOutOfOrderReplies() async throws {
        let mux = RequestMultiplexer<Int>(), recorder = PerformanceRecorder()
        let a = UUID(), b = UUID()
        let first = Task { try await mux.perform(id: a) { await recorder.record() } }
        let second = Task { try await mux.perform(id: b) { await recorder.record() } }
        try await eventually { await recorder.count == 2 }
        await mux.resolve(id: b, result: .success(2))
        await mux.resolve(id: a, result: .success(1))
        let valueA = try await first.value, valueB = try await second.value
        XCTAssertEqual(valueA, 1); XCTAssertEqual(valueB, 2)
        await mux.resolve(id: a, result: .success(99))
        let count = await mux.count
        XCTAssertEqual(count, 0)
        await mux.close()
    }

    func testMultiplexerCancellationDoesNotCloseOtherRequests() async throws {
        let mux = RequestMultiplexer<Int>(), recorder = PerformanceRecorder()
        let a = UUID(), b = UUID()
        let first = Task { try await mux.perform(id: a) { await recorder.record() } }
        let second = Task { try await mux.perform(id: b) { await recorder.record() } }
        try await eventually { await recorder.count == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        await mux.resolve(id: a, result: .success(99))
        await mux.resolve(id: b, result: .success(2))
        let value = try await second.value
        XCTAssertEqual(value, 2)
        let sends = await recorder.count
        XCTAssertEqual(sends, 2)
        await mux.close()
    }

    func testMultiplexerDeadlineDoesNotRetryMutation() async throws {
        let mux = RequestMultiplexer<Int>(timeout: .milliseconds(20)), recorder = PerformanceRecorder()
        do { _ = try await mux.perform { await recorder.record() }; XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? RequestMultiplexer<Int>.Failure, .timedOut) }
        let sends = await recorder.count, pending = await mux.count
        XCTAssertEqual(sends, 1); XCTAssertEqual(pending, 0)
        await mux.close()
    }

    func testMultiplexerRejectsOverloadAndDuplicateIDs() async throws {
        let mux = RequestMultiplexer<Int>(limit: 1), recorder = PerformanceRecorder()
        let id = UUID()
        let first = Task { try await mux.perform(id: id) { await recorder.record() } }
        try await eventually { await recorder.count == 1 }
        do { _ = try await mux.perform(id: id) {}; XCTFail("Expected duplicate rejection") }
        catch { XCTAssertEqual(error as? RequestMultiplexer<Int>.Failure, .duplicateID) }
        do { _ = try await mux.perform {}; XCTFail("Expected overload") }
        catch { XCTAssertEqual(error as? RequestMultiplexer<Int>.Failure, .overloaded) }
        await mux.close()
        do { _ = try await first.value; XCTFail("Expected closure") }
        catch { XCTAssertEqual(error as? RequestMultiplexer<Int>.Failure, .closed) }
    }

    func testCoalescerCollapsesBurstAndRetainsTrailingRefresh() async throws {
        let gate = PerformanceGate(), recorder = PerformanceRecorder()
        let coalescer = RefreshCoalescer(minimumInterval: .milliseconds(10)) {
            await recorder.record()
            await gate.wait()
        }
        await coalescer.invalidate(immediate: true)
        try await eventually { await recorder.count == 1 }
        for _ in 0..<100 { await coalescer.invalidate() }
        let before = await recorder.count
        XCTAssertEqual(before, 1)
        await gate.open()
        await coalescer.waitUntilIdle()
        let after = await recorder.count
        XCTAssertEqual(after, 2)
        await coalescer.cancel()
        await coalescer.invalidate()
        let closedCount = await recorder.count
        XCTAssertEqual(closedCount, 2)
    }

    func testCoalescerRateLimitAppliesDuringContinuousInvalidation() async throws {
        let recorder = PerformanceRecorder()
        let coalescer = RefreshCoalescer(minimumInterval: .milliseconds(25)) { await recorder.record() }
        for _ in 0..<30 {
            await coalescer.invalidate(immediate: true)
            try await Task.sleep(for: .milliseconds(2))
        }
        await coalescer.waitUntilIdle()
        let starts = await recorder.instants
        XCTAssertGreaterThanOrEqual(starts.count, 2)
        for (a, b) in zip(starts, starts.dropFirst()) {
            // Allow scheduling jitter around the actor hop used by the recorder.
            XCTAssertGreaterThanOrEqual(a.duration(to: b), .milliseconds(20))
        }
        await coalescer.cancel()
    }

    @MainActor
    func testTerminalBatcherBoundsDeliveriesAndPreservesAllBytes() async throws {
        var delivered = Data(), sizes: [Int] = []
        let batcher = TerminalOutputBatcher(maximumQueuedBytes: 127, immediateDrainBytes: 64, maximumDeliveryBytes: 31) {
            delivered.append($0); sizes.append($0.count)
        }
        let input = Data((0..<8_000).map { UInt8($0 % 251) })
        await batcher.append(input)
        await batcher.finish()
        XCTAssertEqual(delivered, input)
        XCTAssertTrue(sizes.allSatisfy { $0 <= 31 })
        XCTAssertGreaterThan(sizes.count, 1)
    }

    @MainActor
    func testTerminalBatcherAcceptsNonzeroBasedDataSlices() async {
        var delivered = Data()
        let batcher = TerminalOutputBatcher(maximumDeliveryBytes: 2) { delivered.append($0) }
        let original = Data([0, 1, 2, 3, 4, 5])
        let slice = original[2..<5]
        XCTAssertEqual(slice.startIndex, 2)
        await batcher.append(slice)
        await batcher.append(Data([6]))
        await batcher.finish()
        XCTAssertEqual(delivered, Data([2, 3, 4, 6]))
    }

    @MainActor
    func testTerminalBatcherCancellationUnblocksBackpressure() async throws {
        let gate = PerformanceGate(), recorder = PerformanceRecorder()
        let batcher = TerminalOutputBatcher(maximumQueuedBytes: 2, immediateDrainBytes: 1, maximumDeliveryBytes: 1) { data in
            await recorder.record(data)
            await gate.wait()
        }
        let append = Task { await batcher.append(Data(repeating: 1, count: 100)) }
        try await eventually { await recorder.count == 1 }
        await batcher.cancel()
        await append.value
        await gate.open()
        await batcher.finish()
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }
}
