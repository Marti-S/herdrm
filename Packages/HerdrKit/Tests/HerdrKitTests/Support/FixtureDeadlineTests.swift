import XCTest
@testable import HerdrKit

@MainActor
final class FixtureDeadlineTests: XCTestCase {
    private func expectTimeout(_ message: String, _ body: () async throws -> Void) async throws {
        let start = ContinuousClock.now
        do {
            try await body()
            XCTFail("Expected timeout: \(message)")
        } catch let error as FixtureTimeout {
            XCTAssertEqual(error.message, message)
            XCTAssertTrue(error.description.contains("FixtureDeadlineTests.swift"))
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testImpossibleObservationHasDiagnosticDeadline() async throws {
        try await expectTimeout("missing event") {
            try await waitForFixture("missing event", timeout: .milliseconds(20)) { false }
        }
    }

    func testCancelledSemanticTicketWaitTimesOutThenCanDrain() async throws {
        let gate = fixtureGate("semantic timeout test")
        var entered = false
        let queue = TerminalInputQueue(sendTerminal: { _ in }, resizeTerminal: { _ in }) { _, _ in
            entered = true
            await gate.waitOnFirstCall()
        }
        let ticket = queue.submitSemantic(method: "held", params: .object([:]))
        let operation = fixtureTask("held semantic ticket") { try await ticket.value() }
        try await waitForFixture("semantic sender entered") { entered }
        operation.cancel()
        try await expectTimeout("held semantic ticket") {
            try await operation.value(timeout: .milliseconds(20))
        }
        gate.release()
        try await operation.value()
        try await withFixtureDeadline("following ticket still drains") {
            try await queue.submitSemantic(method: "following", params: .object([:])).value()
        }
    }

    func testOutputFinishTimeoutDoesNotJoinCancellationInsensitiveDelivery() async throws {
        let gate = fixtureGate("held output delivery")
        var entered = false
        let batcher = TerminalOutputBatcher(maximumQueuedBytes: 1, immediateDrainBytes: 1) { _ in
            entered = true
            await gate.waitOnFirstCall()
        }
        let append = fixtureTask("append before timeout") { await batcher.append(Data([1])) }
        try await append.value()
        try await waitForFixture("delivery entered") { entered }
        let finish = fixtureTask("held output finish") { await batcher.finish() }
        try await expectTimeout("held output finish") {
            try await finish.value(timeout: .milliseconds(20))
        }
        // cancel does not release the delivery continuation. Cleanup must not
        // await finish.value without its own deadline.
        await batcher.cancel()
        gate.release()
        try await finish.value()
    }

    func testGateReleaseBeforeWaitAndRepeatedReleaseAreSafe() async throws {
        let gate = fixtureGate("released before starting")
        gate.release()
        gate.release()
        try await withFixtureDeadline("released gate") { await gate.waitOnFirstCall() }
    }

    func testOperationFailureIsNotHiddenByDeadline() async throws {
        enum Rejected: Error { case operation }
        do {
            try await withFixtureDeadline("failing operation") { throw Rejected.operation }
            XCTFail("Expected original operation error")
        } catch Rejected.operation {
            // The fixture must propagate the real failure, not swallow it or
            // replace it with a timeout diagnostic.
        }
    }

    func testTaskTimeoutReportsOriginalCallSite() async throws {
        let gate = fixtureGate("call site probe")
        let operation = fixtureTask("call site probe") { await gate.waitOnFirstCall() }
        do {
            try await operation.value(timeout: .milliseconds(20), file: "Caller.swift", line: 42)
            XCTFail("Expected timeout")
        } catch let error as FixtureTimeout {
            XCTAssertEqual(error.description, "Timed out: call site probe at Caller.swift:42")
        }
        gate.release()
        try await operation.value()
    }

    /// The gate runs this test in subprocesses with one fault at a time. Normal
    /// suite runs exercise a successful operation; faults must exit nonzero with
    /// the exact diagnostic, not by process timeout, crash, or empty selection.
    func testFailureProbe() async throws {
        let mode = ProcessInfo.processInfo.environment["PR26_FIXTURE_FAILURE"] ?? "none"
        switch mode {
        case "poll":
            try await waitForFixture("probe missing event", timeout: .milliseconds(20)) { false }
        case "expectation":
            await fulfillment(of: [expectation(description: "probe missing expectation")], timeout: 0.02)
        case "gate":
            let gate = FixtureGate("probe unreleased gate", timeout: .milliseconds(20))
            defer { gate.release() }
            await gate.waitOnFirstCall()
        case "input":
            let gate = fixtureGate("probe input delivery")
            let queue = TerminalInputQueue(sendTerminal: { _ in }, resizeTerminal: { _ in }) { _, _ in
                await gate.waitOnFirstCall()
            }
            let operation = fixtureTask("probe input completion") {
                try await queue.enqueueSemantic(method: "held", params: .object([:]))
            }
            try await operation.value(timeout: .milliseconds(20))
        case "output", "cleanup":
            let gate = fixtureGate("probe output delivery")
            var entered = false
            let batcher = TerminalOutputBatcher(maximumQueuedBytes: 1, immediateDrainBytes: 1) { _ in
                entered = true
                await gate.waitOnFirstCall()
            }
            try await withFixtureDeadline("probe initial append") { await batcher.append(Data([1])) }
            try await waitForFixture("probe delivery entered") { entered }
            let operation = FixtureTask("probe \(mode) completion") { await batcher.finish() }
            addTeardownBlock { @MainActor in
                defer { gate.release(); operation.cancel() }
                await batcher.cancel()
                if mode == "cleanup" {
                    // Deliberately try to join a cancellation-insensitive finish
                    // during teardown. The bounded join must fail and return.
                    try await operation.value(timeout: .milliseconds(20))
                }
            }
            if mode == "output" {
                try await operation.value(timeout: .milliseconds(20))
            } else {
                // Ensure finish is already awaiting delivery before cancel.
                await Task.yield()
            }
        case "none":
            let value = try await withFixtureDeadline("successful probe") { 42 }
            XCTAssertEqual(value, 42)
        default:
            XCTFail("Unknown failure probe: \(mode)")
        }
    }
}
