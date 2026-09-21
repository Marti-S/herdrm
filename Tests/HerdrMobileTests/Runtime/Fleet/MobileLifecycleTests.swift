import Foundation
import HerdrKit
import XCTest

@MainActor
final class MobileLifecycleTests: XCTestCase {
  private func bridgeFixture() -> BridgeFixture {
    let fixture = BridgeFixture()
    addTeardownBlock { @MainActor in try await fixture.finish() }
    return fixture
  }

  private func directFixture() -> DirectFixture {
    let fixture = DirectFixture()
    addTeardownBlock { @MainActor in try await fixture.finish() }
    return fixture
  }

  func testBridgeRetryRejectsOldRefreshSuccessAndKeepsLiveRevisions() async throws {
    let f = bridgeFixture()
    try await f.connect()
    let old = try await f.refresh()
    try await f.retry()
    try await f.send(1, on: 1)
    let changes = f.changes
    f.requests.resolve(0, .success(FleetSnapshot(revision: 100, devices: [])))
    try await old.join()
    XCTAssertEqual(f.session.snapshot?.revision, 1)
    XCTAssertEqual(f.changes, changes)
    try await f.send(2, on: 1)
    try await f.send(3, on: 1)
    XCTAssertTrue(f.session.state.isConnected)
  }

  func testBridgeRetryRejectsOldRefreshFailure() async throws {
    let f = bridgeFixture()
    try await f.connect()
    let old = try await f.refresh()
    try await f.retry()
    try await f.send(1, on: 1)
    let changes = f.changes
    f.requests.resolve(0, .failure(LifecycleTestError.dropped))
    try await old.join()
    XCTAssertTrue(f.session.state.isConnected)
    XCTAssertEqual(f.changes, changes)
  }

  func testBridgeDisconnectRejectsLateSuccessAndFailure() async throws {
    for succeeds in [true, false] {
      let f = bridgeFixture()
      try await f.connect()
      let old = try await f.refresh()
      let disconnect = f.start { await f.session.disconnect() }
      try await disconnect.join()
      let changes = f.changes
      f.requests.resolve(
        0,
        succeeds
          ? .success(FleetSnapshot(revision: 100, devices: []))
          : .failure(LifecycleTestError.dropped))
      try await old.join()
      XCTAssertEqual(f.session.state, .idle)
      XCTAssertEqual(f.session.snapshot?.revision, 90)
      XCTAssertEqual(f.changes, changes)
    }
  }

  func testBridgeExplicitReconnectRejectsOldRefresh() async throws {
    let f = bridgeFixture()
    try await f.connect()
    let old = try await f.refresh()
    let reconnect = f.start { await f.session.reconnect() }
    try await reconnect.join()
    try await eventually("explicit replacement subscription") { f.streams.count == 2 }
    try await f.send(1, on: 1)
    f.requests.resolve(0, .success(FleetSnapshot(revision: 100, devices: [])))
    try await old.join()
    XCTAssertEqual(f.session.snapshot?.revision, 1)
    try await f.send(2, on: 1)
  }

  func testBridgeSameEpochRejectsRefreshBehindSubscriptionAndLateFailure() async throws {
    for succeeds in [true, false] {
      let f = bridgeFixture()
      try await f.connect(revision: 1)
      let old = try await f.refresh()
      try await f.send(3, on: 0)
      let changes = f.changes
      f.requests.resolve(
        0,
        succeeds
          ? .success(FleetSnapshot(revision: 2, devices: []))
          : .failure(LifecycleTestError.dropped))
      try await old.join()
      XCTAssertEqual(f.session.snapshot?.revision, 3)
      XCTAssertTrue(f.session.state.isConnected)
      XCTAssertEqual(f.changes, changes)
    }
  }

  func testBridgeOverlappingRefreshesCannotRegressAndCancelledRefreshCannotPublish() async throws {
    let f = bridgeFixture()
    try await f.connect(revision: 1)
    let first = try await f.refresh()
    let second = try await f.refresh()
    f.requests.resolve(1, .success(FleetSnapshot(revision: 3, devices: [])))
    try await second.join()
    f.requests.resolve(0, .success(FleetSnapshot(revision: 100, devices: [])))
    try await first.join()
    XCTAssertEqual(f.session.snapshot?.revision, 3)
    let cancelled = try await f.refresh()
    cancelled.task?.cancel()
    f.requests.resolve(2, .success(FleetSnapshot(revision: 100, devices: [])))
    try await cancelled.join()
    XCTAssertEqual(f.session.snapshot?.revision, 3)
    try await f.send(4, on: 0)
  }

  func testBridgeFirstSubscriptionSnapshotOverridesPreSubscriptionRefresh() async throws {
    let f = bridgeFixture()
    f.session.connect()
    try await eventually("subscription opened") { f.streams.count == 1 }
    let old = try await f.refresh()
    try await f.send(1, on: 0)
    f.requests.resolve(0, .success(FleetSnapshot(revision: 100, devices: [])))
    try await old.join()
    XCTAssertEqual(f.session.snapshot?.revision, 1)
    try await f.send(2, on: 0)
  }

  func testBridgeDeduplicatesAndRejectsLowerSameEpochRefresh() async throws {
    let f = bridgeFixture()
    try await f.connect(revision: 3)
    let changes = f.changes
    let duplicate = try await f.refresh()
    f.requests.resolve(0, .success(FleetSnapshot(revision: 3, devices: [])))
    try await duplicate.join()
    XCTAssertEqual(f.changes, changes)
    let stale = try await f.refresh()
    f.requests.resolve(1, .success(FleetSnapshot(revision: 2, devices: [])))
    try await stale.join()
    XCTAssertEqual(f.session.snapshot?.revision, 3)
    XCTAssertEqual(f.changes, changes)
    // FIFO delivery: seeing 4 proves the preceding duplicate and stale records
    // were consumed, without a sleep standing in for an assertion.
    f.streams[0].yield(FleetSnapshot(revision: 3, devices: []))
    f.streams[0].yield(FleetSnapshot(revision: 2, devices: []))
    try await f.send(4, on: 0)
    XCTAssertEqual(f.changes, changes + 1)
    try await f.retry()
    let beforeReconnect = f.changes
    try await f.send(4, on: 1)
    try await f.send(5, on: 1)
    XCTAssertEqual(f.changes, beforeReconnect + 1)
  }

  func testDirectReplacementDoesNotJoinObsoleteDebounce() async throws {
    let f = directFixture()
    try await f.connect()
    f.first.event()
    try await eventually("old debounced worker") { f.debounce.count == 1 }
    try await f.dropAndRetry()
    try await eventually("replacement initial snapshot before old debounce completes") {
      f.session.snapshot?.version == "connection-2"
    }
    XCTAssertEqual(f.second.requests, 1)
    f.debounce.resolve(0, .success(()))
    try await eventually("cancelled debounce retired") {
      f.debounce.completionWasCancelled[0] != nil
    }
    XCTAssertEqual(f.debounce.completionWasCancelled[0], true)
    let refresh = f.start { await f.session.refresh() }
    try await refresh.join()
    XCTAssertEqual(f.session.snapshot?.version, "connection-2")
    XCTAssertEqual(f.first.requests, 1)
    XCTAssertEqual(f.second.requests, 2)
  }

  func testDirectReplacementDoesNotJoinObsoleteInflightWorkerOrLoseNewWorker() async throws {
    let f = directFixture()
    try await f.connect()
    f.first.holdSnapshots = true
    let old = f.start { await f.session.refresh() }
    try await eventually("old in-flight snapshot") { f.first.replies.count == 1 }
    f.second.holdSnapshots = true
    try await f.dropAndRetry()
    try await eventually("replacement initial snapshot requested independently") {
      f.second.replies.count == 1
    }
    f.first.replies.resolve(0, .success(snapshotReply("obsolete")))
    try await old.join()
    XCTAssertEqual(f.first.replies.completionWasCancelled[0], true)
    XCTAssertEqual(f.session.snapshot?.version, "connection-1")
    // An old worker's cleanup must not clear ownership of the new worker.
    let joined = f.start { await f.session.refresh() }
    try await eventually("refresh joined the replacement worker") { f.session.refreshDirty }
    XCTAssertEqual(f.second.requests, 1, "Joining must not launch a second worker")
    f.second.replies.resolve(0, .success(snapshotReply("connection-2")))
    try await eventually("coalesced follow-up snapshot") { f.second.replies.count == 2 }
    XCTAssertEqual(f.second.requests, 2)
    f.second.replies.resolve(1, .success(snapshotReply("connection-2-current")))
    try await joined.join()
    XCTAssertEqual(f.session.snapshot?.version, "connection-2-current")
    XCTAssertTrue(f.session.state.isConnected)
  }

  func testDirectDisconnectCancelsWorkerAndLateResultCannotPublish() async throws {
    let f = directFixture()
    try await f.connect()
    f.first.holdSnapshots = true
    let old = f.start { await f.session.refresh() }
    try await eventually("in-flight snapshot before disconnect") { f.first.replies.count == 1 }
    try await f.start { await f.session.disconnect() }.join()
    f.first.replies.resolve(0, .success(snapshotReply("obsolete")))
    try await old.join()
    XCTAssertEqual(f.session.state, .idle)
    XCTAssertEqual(f.session.snapshot?.version, "connection-1")
    try await f.start { await f.session.connect() }.join()
    XCTAssertEqual(f.session.snapshot?.version, "connection-2")
    XCTAssertEqual(f.first.closes, 1)
  }

  func testBridgeDropInvalidatesRefreshDuringBackoff() async throws {
    for succeeds in [true, false] {
      let f = bridgeFixture()
      try await f.connect()
      let old = try await f.refresh()
      f.streams[0].finish(throwing: LifecycleTestError.dropped)
      try await eventually("bridge backoff before retry") { f.delays.count == 1 }
      let changes = f.changes
      f.requests.resolve(
        0,
        succeeds
          ? .success(FleetSnapshot(revision: 100, devices: []))
          : .failure(LifecycleTestError.dropped))
      try await old.join()
      XCTAssertEqual(f.session.snapshot?.revision, 90)
      XCTAssertTrue(f.session.state.isConnected)
      XCTAssertEqual(f.changes, changes)
    }
  }

  func testBridgeFirstSnapshotResetsAlreadyPublishedRefreshRevision() async throws {
    let f = bridgeFixture()
    f.session.connect()
    try await eventually("subscription awaiting first snapshot") { f.streams.count == 1 }
    let refresh = try await f.refresh()
    f.requests.resolve(0, .success(FleetSnapshot(revision: 100, devices: [])))
    try await refresh.join()
    XCTAssertEqual(f.session.snapshot?.revision, 100)
    try await f.send(1, on: 0)
    try await f.send(2, on: 0)
  }

  func testBridgeCurrentRefreshFailureIsVisibleAndCurrentSuccessRecovers() async throws {
    let f = bridgeFixture()
    try await f.connect(revision: 1)
    let failed = try await f.refresh()
    f.requests.resolve(0, .failure(LifecycleTestError.dropped))
    try await failed.join()
    guard case .failed = f.session.state else {
      return XCTFail("Current refresh failure was hidden")
    }
    let recovered = try await f.refresh()
    f.requests.resolve(1, .success(FleetSnapshot(revision: 1, devices: [])))
    try await recovered.join()
    XCTAssertTrue(f.session.state.isConnected)
    try await f.send(2, on: 0)
  }

  func testDirectEventRefreshLateSuccessAndFailureAcrossRetry() async throws {
    for completeBeforeRetry in [true, false] {
      for succeeds in [true, false] {
        let f = directFixture()
        try await f.connect()
        f.first.holdSnapshots = true
        f.first.event()
        try await eventually("event debounce") { f.debounce.count == 1 }
        f.debounce.resolve(0, .success(()))
        try await eventually("event refresh in flight") { f.first.replies.count == 1 }
        let old = f.start { await f.session.refresh() }
        try await eventually("joined old event worker") { f.session.refreshDirty }
        f.first.drop()
        try await eventually("direct retry backoff") { f.retryDelay.count == 1 }

        if !completeBeforeRetry {
          f.retryDelay.resolve(0, .success(()))
          try await eventually("replacement snapshot") {
            f.session.snapshot?.version == "connection-2"
          }
        }
        f.first.replies.resolve(
          0,
          succeeds
            ? .success(snapshotReply("obsolete"))
            : .failure(LifecycleTestError.dropped))
        try await old.join()
        XCTAssertEqual(f.first.replies.completionWasCancelled[0], true)
        XCTAssertEqual(
          f.session.snapshot?.version, completeBeforeRetry ? "connection-1" : "connection-2")
        XCTAssertTrue(f.session.state.isConnected)
        if completeBeforeRetry {
          f.retryDelay.resolve(0, .success(()))
          try await eventually("replacement snapshot") {
            f.session.snapshot?.version == "connection-2"
          }
        }
        XCTAssertEqual(f.second.requests, 1)
        XCTAssertEqual(f.first.closes, 1)
      }
    }
  }
}
