import Foundation
import HerdrKit
import XCTest

@MainActor
private final class ForegroundRetryFixture {
  let initial = DirectTransportFixture("initial")
  let foreground = DirectTransportFixture("foreground")
  let obsolete = DirectTransportFixture("obsolete-retry")
  let delays = Suspensions<Void>("foreground retry backoff")
  var opens = 0
  var sleeps = 0
  var operations: [LifecycleOperation] = []
  lazy var session = MobileDeviceSession(
    device: MobileDevice(name: "Synthetic foreground retry", host: "invalid.example"),
    openTransport: { [unowned self] _ in
      self.opens += 1
      switch self.opens {
      case 1: return self.initial
      case 2, 3: throw LifecycleTestError.dropped
      case 4: return self.foreground
      case 5: return self.obsolete
      default: throw LifecycleTestError.unexpectedCall
      }
    },
    sleep: { [unowned self] duration in
      guard duration != .milliseconds(300) else { throw LifecycleTestError.unexpectedCall }
      self.sleeps += 1
      if self.sleeps == 2 {
        // Grace uses the real monotonic clock. No fixture continuation is held
        // over this finite wait, which deliberately crosses the real threshold.
        try await Task.sleep(for: MobileDeviceSession.failureGrace + .milliseconds(100))
      } else {
        try await self.delays.wait()
      }
    }
  )

  func start(_ body: @escaping @MainActor () async -> Void) -> LifecycleOperation {
    let operation = LifecycleOperation(body)
    operations.append(operation)
    return operation
  }

  func finish() async throws {
    operations.forEach { $0.task?.cancel() }
    let stopping = start { [self] in await session.disconnect() }
    initial.finish()
    foreground.finish()
    obsolete.finish()
    delays.finish()
    try await stopping.join()
    try await eventually("foreground retry operations drained") { operations.allSatisfy(\.done) }
  }
}

extension MobileLifecycleTests {
  func testDirectConnectRetiresOlderRetryWithoutCancellingInitialSnapshot() async throws {
    try await foregroundSupersedesRetry(useResume: false)
  }

  func testDirectResumeRetiresOlderRetryWithoutCancellingInitialSnapshot() async throws {
    try await foregroundSupersedesRetry(useResume: true)
  }

  private func foregroundSupersedesRetry(useResume: Bool) async throws {
    let f = ForegroundRetryFixture()
    addTeardownBlock { @MainActor in try await f.finish() }
    try await f.start { await f.session.connect() }.join()
    XCTAssertEqual(f.session.snapshot?.version, "initial")
    f.initial.drop()
    try await eventually("first automatic retry sleeping") { f.delays.count == 1 }
    XCTAssertTrue(f.session.state.isConnected, "Grace must retain connected state")
    f.delays.resolve(0, .success(()))
    try await eventually("failed retry after grace expiry", timeout: .seconds(12)) {
      f.delays.count == 2 && f.opens == 3
    }
    guard case .failed = f.session.state else {
      return XCTFail("Expected failure after production grace period")
    }

    f.foreground.holdSnapshots = true
    let foreground = f.start {
      if useResume { await f.session.resume() } else { await f.session.connect() }
    }
    try await eventually("foreground initial snapshot pending") {
      f.opens == 4 && f.foreground.replies.count == 1
    }
    // Cancellation-insensitive sleep returns successfully after foreground takes
    // ownership. Observe cancellation through the injected boundary, not private tasks.
    f.delays.resolve(1, .success(()))
    try await eventually("obsolete retry sleep returned") {
      f.delays.completionWasCancelled[1] != nil
    }
    XCTAssertEqual(f.delays.completionWasCancelled[1], true)
    XCTAssertEqual(f.opens, 4, "Obsolete retry must not open another transport")
    XCTAssertEqual(f.foreground.closes, 0)
    XCTAssertEqual(f.session.snapshot?.version, "initial")

    f.foreground.replies.resolve(0, .success(snapshotReply("foreground")))
    try await foreground.join()
    XCTAssertEqual(f.foreground.replies.completionWasCancelled[0], false)
    XCTAssertEqual(f.session.snapshot?.version, "foreground")
    XCTAssertEqual(f.session.state, .connected(version: "foreground"))
    XCTAssertEqual(f.foreground.requests, 1)
    XCTAssertEqual(f.obsolete.requests, 0)
    XCTAssertEqual(f.opens, 4)
    XCTAssertEqual(f.foreground.closes, 0)
  }

  func testDirectConnectFailurePreservesAutomaticRecovery() async throws {
    try await foregroundFailurePreservesRecovery(useResume: false)
  }

  func testDirectResumeFailurePreservesAutomaticRecovery() async throws {
    try await foregroundFailurePreservesRecovery(useResume: true)
  }

  private func failedRetryFixture() async throws -> ForegroundRetryFixture {
    let f = ForegroundRetryFixture()
    addTeardownBlock { @MainActor in try await f.finish() }
    try await f.start { await f.session.connect() }.join()
    XCTAssertEqual(f.session.snapshot?.version, "initial")
    f.initial.drop()
    try await eventually("first recovery backoff") { f.delays.count == 1 }
    XCTAssertTrue(f.session.state.isConnected, "Grace must retain connected state")
    f.delays.resolve(0, .success(()))
    try await eventually("automatic recovery continues after grace", timeout: .seconds(12)) {
      f.delays.count == 2 && f.opens == 3
    }
    guard case .failed = f.session.state else {
      XCTFail("Expected visible failure after production grace period")
      throw LifecycleTestError.unexpectedCall
    }
    return f
  }

  // Read-only inspection gives a bounded completion barrier for retired tasks.
  private func foregroundRetryTask(_ session: MobileDeviceSession) -> Task<Void, Never>? {
    Mirror(reflecting: session).children.first { $0.label == "reconnectTask" }?.value
      as? Task<Void, Never>
  }

  private func foregroundFailurePreservesRecovery(useResume: Bool) async throws {
    let f = try await failedRetryFixture()
    let oldRetry = try XCTUnwrap(foregroundRetryTask(f.session))
    f.foreground.holdPing = true
    let foreground = f.start {
      if useResume { await f.session.resume() } else { await f.session.connect() }
    }
    try await eventually("foreground ping pending") { f.foreground.pings.count == 1 }
    f.foreground.pings.resolve(0, .failure(LifecycleTestError.dropped))
    try await foreground.join()
    XCTAssertEqual(f.opens, 4)
    XCTAssertEqual(f.foreground.closes, 1, "Failed candidate must close exactly once")
    XCTAssertEqual(f.session.snapshot?.version, "initial")
    guard case .failed = f.session.state else { return XCTFail("Foreground ping must fail") }
    let replacement = try XCTUnwrap(foregroundRetryTask(f.session),
      "Failed foreground takeover must install a replacement automatic retry owner")
    XCTAssertTrue(oldRetry.isCancelled)
    XCTAssertFalse(replacement.isCancelled)
    try await eventually("replacement recovery backoff") { f.delays.count == 3 }

    // Drain the obsolete loop after replacement ownership has been installed.
    f.delays.resolve(1, .success(()))
    try await f.start { await oldRetry.value }.join()
    XCTAssertEqual(f.delays.completionWasCancelled[1], true)
    XCTAssertNotNil(foregroundRetryTask(f.session), "Old cleanup must not erase replacement ownership")
    XCTAssertEqual(f.opens, 4, "Obsolete loop must not open another transport")
    f.delays.resolve(2, .success(()))
    try await f.start { await replacement.value }.join()
    XCTAssertEqual(f.opens, 5, "Recovery must not require another foreground action")
    XCTAssertEqual(f.session.state, .connected(version: "obsolete-retry"))
    XCTAssertEqual(f.session.snapshot?.version, "obsolete-retry")
    XCTAssertEqual(f.obsolete.requests, 1, "Replacement must obtain its initial snapshot")
    XCTAssertEqual(f.obsolete.closes, 0)
    XCTAssertNil(foregroundRetryTask(f.session), "Completed retry must release ownership")
  }

  func testDirectForegroundFailureCannotRestartRecoveryAfterDisconnect() async throws {
    try await retiredForegroundFailure(action: "disconnect")
  }

  func testDirectForegroundFailureCannotReplaceNewConnection() async throws {
    try await retiredForegroundFailure(action: "replace")
  }

  func testDirectCancelledForegroundFailureCannotRestartRecovery() async throws {
    try await retiredForegroundFailure(action: "cancel")
  }

  private func retiredForegroundFailure(action: String) async throws {
    let f = try await failedRetryFixture()
    let oldRetry = try XCTUnwrap(foregroundRetryTask(f.session))
    f.foreground.holdPing = true
    let foreground = f.start { await f.session.connect() }
    try await eventually("foreground ping before supersession") { f.foreground.pings.count == 1 }
    if action == "cancel" {
      foreground.task?.cancel()
    } else {
      try await f.start { await f.session.disconnect() }.join()
      if action == "replace" { try await f.start { await f.session.connect() }.join() }
    }
    let stateBeforeFailure = f.session.state
    f.foreground.pings.resolve(0, .failure(LifecycleTestError.dropped))
    try await foreground.join()
    f.delays.resolve(1, .success(()))
    try await f.start { await oldRetry.value }.join()
    XCTAssertTrue(oldRetry.isCancelled)
    XCTAssertNil(foregroundRetryTask(f.session), "Retired foreground failure must not create recovery")
    XCTAssertEqual(f.delays.count, 2, "No replacement retry may be scheduled")
    XCTAssertEqual(f.opens, action == "replace" ? 5 : 4)
    XCTAssertEqual(f.foreground.closes, 1)
    if action == "cancel" {
      XCTAssertEqual(f.foreground.pings.completionWasCancelled[0], true)
      guard case .failed = f.session.state else { return XCTFail("Expected failed foreground state") }
    } else {
      XCTAssertEqual(f.session.state, stateBeforeFailure)
    }
    XCTAssertEqual(f.session.snapshot?.version, action == "replace" ? "obsolete-retry" : "initial")
    if action == "replace" {
      XCTAssertEqual(f.obsolete.requests, 1)
      XCTAssertEqual(f.obsolete.closes, 0)
    } else {
      XCTAssertNil(f.session.transport)
    }
  }

  func testDirectInitialFailureDoesNotStartAutomaticRecovery() async throws {
    let f = DirectFixture()
    addTeardownBlock { @MainActor in try await f.finish() }
    f.first.holdPing = true
    let connecting = f.start { await f.session.connect() }
    try await eventually("initial ping pending") { f.first.pings.count == 1 }
    f.first.pings.resolve(0, .failure(LifecycleTestError.dropped))
    try await connecting.join()
    guard case .failed = f.session.state else { return XCTFail("Expected initial failure") }
    XCTAssertNil(foregroundRetryTask(f.session))
    XCTAssertNil(f.session.transport)
    XCTAssertNil(f.session.snapshot)
    XCTAssertEqual(f.opens, 1)
    XCTAssertEqual(f.first.closes, 1)
    XCTAssertEqual(f.retryDelay.count, 0)
  }
}
