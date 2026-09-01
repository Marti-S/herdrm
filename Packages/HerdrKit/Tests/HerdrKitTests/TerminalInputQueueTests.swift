import XCTest
@testable import HerdrKit

final class TerminalInputQueueTests: XCTestCase {
    @MainActor
    func testMixedOperationsExecuteInStrictFIFOWithOneInFlight() async throws {
        let firstStarted = expectation(description: "first semantic started")
        let gate = InputGate()
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

        let first = Task { try await queue.enqueueSemantic(method: "first", params: JSONValue.object([:])) }
        await fulfillment(of: [firstStarted])
        queue.enqueueTerminal(Data("a".utf8), generation: 1)
        queue.enqueueTerminal(Data("b".utf8), generation: 1)
        queue.enqueueResize(TerminalSize(columns: 100, rows: 30), generation: 1)
        let last = Task { try await queue.enqueueSemantic(method: "last", params: JSONValue.object([:])) }
        await waitUntil { queue.pendingOperationCount == 3 }

        await gate.release()
        try await first.value
        try await last.value

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
        let gate = InputGate()
        let recorder = InputRecorder()
        let queue = makeQueue(recorder: recorder) { method, _ in
            if method == "blocker" {
                blockerStarted.fulfill()
                await gate.waitOnFirstCall()
            }
            recorder.record("semantic:\(method)")
        }

        let blocker = Task {
            try await queue.enqueueSemantic(method: "blocker", params: JSONValue.object([:]))
        }
        await fulfillment(of: [blockerStarted])
        queue.enqueueTerminal(Data("one".utf8), generation: 1)
        queue.enqueueTerminal(Data("two".utf8), generation: 1)
        XCTAssertEqual(queue.pendingOperationCount, 1)

        await gate.release()
        try await blocker.value
        await waitUntil { recorder.events.count == 2 }

        XCTAssertEqual(recorder.events, ["semantic:blocker", "terminal:onetwo"])
    }

    @MainActor
    func testRestartDropsStaleSessionInputButKeepsAcceptedSemanticInput() async throws {
        let blockerStarted = expectation(description: "blocker started")
        let gate = InputGate()
        let recorder = InputRecorder()
        let queue = makeQueue(recorder: recorder) { method, _ in
            if method == "blocker" {
                blockerStarted.fulfill()
                await gate.waitOnFirstCall()
            }
            recorder.record("semantic:\(method)")
        }

        let blocker = Task {
            try await queue.enqueueSemantic(method: "blocker", params: JSONValue.object([:]))
        }
        await fulfillment(of: [blockerStarted])
        queue.enqueueTerminal(Data("stale".utf8), generation: 1)
        queue.enqueueResize(TerminalSize(columns: 90, rows: 20), generation: 1)
        let durable = Task {
            try await queue.enqueueSemantic(method: "durable", params: JSONValue.object([:]))
        }
        await waitUntil { queue.pendingOperationCount == 3 }

        queue.updateGeneration(2)
        await gate.release()
        try await blocker.value
        try await durable.value

        XCTAssertEqual(recorder.events, ["semantic:blocker", "semantic:durable"])
    }

    @MainActor
    func testSemanticFailurePropagatesAndDoesNotBlockFollowingOperation() async throws {
        let failureStarted = expectation(description: "failing semantic started")
        let gate = InputGate()
        let recorder = InputRecorder()
        let queue = makeQueue(recorder: recorder) { method, _ in
            if method == "fail" {
                failureStarted.fulfill()
                await gate.waitOnFirstCall()
            }
            recorder.record("semantic:\(method)")
            if method == "fail" { throw InputTestError.rejected }
        }

        let failed = Task {
            do {
                try await queue.enqueueSemantic(method: "fail", params: JSONValue.object([:]))
                return nil as InputTestError?
            } catch {
                return error as? InputTestError
            }
        }
        await fulfillment(of: [failureStarted])
        let following = Task {
            try await queue.enqueueSemantic(method: "following", params: JSONValue.object([:]))
        }
        await waitUntil { queue.pendingOperationCount == 1 }
        await gate.release()

        let failure = await failed.value
        XCTAssertEqual(failure, .rejected)
        try await following.value
        XCTAssertEqual(recorder.events, ["semantic:fail", "semantic:following"])
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

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        while !condition() {
            await Task.yield()
        }
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

private actor InputGate {
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

private enum InputTestError: Error, Equatable {
    case rejected
}
