import XCTest
@testable import HerdrKit

final class TerminalInputQueueTests: XCTestCase {
    @MainActor
    func testMixedOperationsExecuteInStrictFIFOWithOneInFlight() async throws {
        let firstStarted = expectation(description: "first semantic started")
        let gate = fixtureGate("first semantic delivery")
        let recorder = InputRecorder()
        let queue = makeQueue(recorder: recorder) { method, _ in
            recorder.beginOperation()
            if method == "first" {
                firstStarted.fulfill()
                await gate.waitOnFirstCall()
            }
            recorder.record("semantic:\(method)")
            recorder.endOperation()
        }

        let first = fixtureTask("first semantic completion") { try await queue.enqueueSemantic(method: "first", params: JSONValue.object([:])) }
        await fulfillment(of: [firstStarted], timeout: 3)
        queue.enqueueTerminal(Data("a".utf8), generation: 1)
        queue.enqueueTerminal(Data("b".utf8), generation: 1)
        queue.enqueueResize(TerminalSize(columns: 100, rows: 30), generation: 1)
        let last = fixtureTask("last semantic completion") { try await queue.enqueueSemantic(method: "last", params: JSONValue.object([:])) }
        try await waitForFixture("three pending FIFO operations") { queue.pendingOperationCount == 3 }

        gate.release()
        try await first.value()
        try await last.value()

        XCTAssertEqual(recorder.events, [
            "semantic:first",
            "terminal:ab",
            "resize:100x30",
            "semantic:last",
        ])
        XCTAssertEqual(recorder.maximumInFlight, 1)
    }

    @MainActor
    func testAdjacentRawBytesAreCoalescedIntoOneSend() async throws {
        let blockerStarted = expectation(description: "blocker started")
        let gate = fixtureGate("coalescing blocker")
        let recorder = InputRecorder()
        let queue = makeQueue(recorder: recorder) { method, _ in
            if method == "blocker" {
                blockerStarted.fulfill()
                await gate.waitOnFirstCall()
            }
            recorder.record("semantic:\(method)")
        }

        let blocker = fixtureTask("coalescing blocker completion") {
            try await queue.enqueueSemantic(method: "blocker", params: JSONValue.object([:]))
        }
        await fulfillment(of: [blockerStarted], timeout: 3)
        queue.enqueueTerminal(Data("one".utf8), generation: 1)
        queue.enqueueTerminal(Data("two".utf8), generation: 1)
        XCTAssertEqual(queue.pendingOperationCount, 1)

        gate.release()
        try await blocker.value()
        try await waitForFixture("coalesced terminal delivery") { recorder.events.count == 2 }

        XCTAssertEqual(recorder.events, ["semantic:blocker", "terminal:onetwo"])
    }

    @MainActor
    func testRestartDropsStaleSessionInputButKeepsAcceptedSemanticInput() async throws {
        let blockerStarted = expectation(description: "blocker started")
        let gate = fixtureGate("generation blocker")
        let recorder = InputRecorder()
        let queue = makeQueue(recorder: recorder) { method, _ in
            if method == "blocker" {
                blockerStarted.fulfill()
                await gate.waitOnFirstCall()
            }
            recorder.record("semantic:\(method)")
        }

        let blocker = fixtureTask("generation blocker completion") {
            try await queue.enqueueSemantic(method: "blocker", params: JSONValue.object([:]))
        }
        await fulfillment(of: [blockerStarted], timeout: 3)
        queue.enqueueTerminal(Data("stale".utf8), generation: 1)
        queue.enqueueResize(TerminalSize(columns: 90, rows: 20), generation: 1)
        let durable = fixtureTask("durable semantic completion") {
            try await queue.enqueueSemantic(method: "durable", params: JSONValue.object([:]))
        }
        try await waitForFixture("three operations before generation change") { queue.pendingOperationCount == 3 }

        queue.updateGeneration(2)
        gate.release()
        try await blocker.value()
        try await durable.value()

        XCTAssertEqual(recorder.events, ["semantic:blocker", "semantic:durable"])
    }

    @MainActor
    func testSemanticFailurePropagatesAndDoesNotBlockFollowingOperation() async throws {
        let failureStarted = expectation(description: "failing semantic started")
        let gate = fixtureGate("failing semantic delivery")
        let recorder = InputRecorder()
        let queue = makeQueue(recorder: recorder) { method, _ in
            if method == "fail" {
                failureStarted.fulfill()
                await gate.waitOnFirstCall()
            }
            recorder.record("semantic:\(method)")
            if method == "fail" { throw InputTestError.rejected }
        }

        let failed = fixtureTask("failed semantic completion") {
            do {
                try await queue.enqueueSemantic(method: "fail", params: JSONValue.object([:]))
                return nil as InputTestError?
            } catch {
                return error as? InputTestError
            }
        }
        await fulfillment(of: [failureStarted], timeout: 3)
        let following = fixtureTask("following semantic completion") {
            try await queue.enqueueSemantic(method: "following", params: JSONValue.object([:]))
        }
        try await waitForFixture("operation queued behind failure") { queue.pendingOperationCount == 1 }
        gate.release()

        let failure = try await failed.value()
        XCTAssertEqual(failure, .rejected)
        try await following.value()
        XCTAssertEqual(recorder.events, ["semantic:fail", "semantic:following"])
    }

    @MainActor
    func testSubmitSemanticPreservesSynchronousSubmissionOrder() async throws {
        let firstStarted = expectation(description: "first semantic started")
        let gate = fixtureGate("synchronous submission blocker")
        let recorder = InputRecorder()
        let queue = makeQueue(recorder: recorder) { method, _ in
            if method == "first" {
                firstStarted.fulfill()
                await gate.waitOnFirstCall()
            }
            recorder.record("semantic:\(method)")
        }

        let first = queue.submitSemantic(method: "first", params: .object([:]))
        let second = queue.submitSemantic(method: "second", params: .object([:]))
        let third = queue.submitSemantic(method: "third", params: .object([:]))

        await fulfillment(of: [firstStarted], timeout: 3)
        gate.release()
        try await withFixtureDeadline("first ticket") { try await first.value() }
        try await withFixtureDeadline("second ticket") { try await second.value() }
        try await withFixtureDeadline("third ticket") { try await third.value() }

        XCTAssertEqual(recorder.events, [
            "semantic:first",
            "semantic:second",
            "semantic:third",
        ])
    }

    @MainActor
    func testCompletedSemanticTicketCanBeAwaitedRepeatedly() async throws {
        let recorder = InputRecorder()
        let queue = makeQueue(recorder: recorder) { method, _ in
            recorder.record("semantic:\(method)")
            if method == "fail" { throw InputTestError.rejected }
        }

        let succeeded = queue.submitSemantic(method: "success", params: .object([:]))
        let failed = queue.submitSemantic(method: "fail", params: .object([:]))
        try await waitForFixture("both semantic tickets delivered") { recorder.events.count == 2 }

        try await withFixtureDeadline("success ticket first read") { try await succeeded.value() }
        try await withFixtureDeadline("success ticket repeated read") { try await succeeded.value() }
        for _ in 0..<2 {
            do {
                try await withFixtureDeadline("failure ticket read") { try await failed.value() }
                XCTFail("Expected completed failure ticket to throw")
            } catch {
                XCTAssertEqual(error as? InputTestError, .rejected)
            }
        }
    }

    @MainActor
    private func makeQueue(
        recorder: InputRecorder,
        semantic: @escaping TerminalInputQueue.SemanticSender
    ) -> TerminalInputQueue {
        TerminalInputQueue(
            generation: 1,
            sendTerminal: { data in
                recorder.beginOperation()
                recorder.record("terminal:\(String(decoding: data, as: UTF8.self))")
                recorder.endOperation()
            },
            resizeTerminal: { size in
                recorder.beginOperation()
                recorder.record("resize:\(size.columns)x\(size.rows)")
                recorder.endOperation()
            },
            sendSemantic: semantic
        )
    }

}

@MainActor
private final class InputRecorder {
    private(set) var events: [String] = []
    private(set) var maximumInFlight = 0
    private var inFlight = 0

    func beginOperation() {
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
    }

    func endOperation() {
        inFlight -= 1
    }

    func record(_ event: String) {
        events.append(event)
    }
}


private enum InputTestError: Error, Equatable {
    case rejected
}
