import XCTest

@MainActor
final class LifecycleFixtureDeadlineTests: XCTestCase {
    private func expectTimeout(_ message: String, _ body: () async throws -> Void) async throws {
        let start = ContinuousClock.now
        do {
            try await body()
            XCTFail("Expected timeout: \(message)")
        } catch let error as FixtureTimeout {
            XCTAssertEqual(error.message, message)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testObservationTimeoutTerminates() async throws {
        try await expectTimeout("missing lifecycle event") {
            try await eventually("missing lifecycle event", timeout: .milliseconds(20)) { false }
        }
    }

    func testCancelledOperationJoinDoesNotWaitForInsensitiveIO() async throws {
        let io = Suspensions<Void>("cancelled join test")
        defer { io.finish() }
        let operation = LifecycleOperation { try? await io.wait() }
        try await eventually("join I/O started") { io.count == 1 }
        operation.task?.cancel()
        try await expectTimeout("operation completion") {
            try await operation.join(timeout: .milliseconds(20))
        }
        io.finish()
        try await operation.join()
        XCTAssertEqual(io.completionWasCancelled[0], true)
    }

    func testBridgeCleanupTimesOutWithoutJoiningAnInsensitiveTask() async throws {
        let f = BridgeFixture()
        let gate = fixtureGate("extra bridge operation")
        addTeardownBlock { @MainActor in gate.release(); try await f.finish() }
        try await f.connect()
        var entered = false
        let operation = f.start { entered = true; await gate.waitOnFirstCall() }
        try await eventually("extra bridge operation started") { entered }
        try await expectTimeout("bridge operations drained") {
            try await f.finish(timeout: .milliseconds(20))
        }
        XCTAssertTrue(operation.task?.isCancelled == true)
        XCTAssertFalse(operation.done, "Cleanup must return before cancellation-insensitive work")
        gate.release()
        try await f.finish()
        XCTAssertTrue(operation.done)
    }

    func testDirectCleanupTimesOutWithoutJoiningAnInsensitiveTask() async throws {
        let f = DirectFixture()
        let gate = fixtureGate("extra direct operation")
        addTeardownBlock { @MainActor in gate.release(); try await f.finish() }
        try await f.connect()
        var entered = false
        let operation = f.start { entered = true; await gate.waitOnFirstCall() }
        try await eventually("extra direct operation started") { entered }
        try await expectTimeout("direct operations drained") {
            try await f.finish(timeout: .milliseconds(20))
        }
        XCTAssertTrue(operation.task?.isCancelled == true)
        XCTAssertFalse(operation.done)
        gate.release()
        try await f.finish()
        XCTAssertTrue(operation.done)
    }

    func testCleanupReleasesPendingProductionRefreshes() async throws {
        let bridge = BridgeFixture()
        addTeardownBlock { @MainActor in try await bridge.finish() }
        try await bridge.connect()
        let bridgeRefresh = try await bridge.refresh()
        try await bridge.finish()
        XCTAssertTrue(bridgeRefresh.done)
        XCTAssertEqual(bridge.requests.completionWasCancelled[0], true)

        let direct = DirectFixture()
        addTeardownBlock { @MainActor in try await direct.finish() }
        try await direct.connect()
        direct.first.holdSnapshots = true
        let directRefresh = direct.start { await direct.session.refresh() }
        try await eventually("direct refresh suspended") { direct.first.replies.count == 1 }
        try await direct.finish()
        XCTAssertTrue(directRefresh.done)
        XCTAssertEqual(direct.first.replies.completionWasCancelled[0], true)
    }
}
