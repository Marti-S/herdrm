import Foundation
import HerdrKit
import XCTest

@MainActor
private final class BridgeStopFixture {
  let delay = Suspensions<Void>("bridge stop retry")
  var cancellations = 0
  var streams: [AsyncThrowingStream<FleetSnapshot, Error>.Continuation] = []
  var operations: [LifecycleOperation] = []
  lazy var session = MobileBridgeSession(
    bridge: MobileBridge(name: "Synthetic bridge", host: "invalid.example"),
    clientID: UUID(), clientName: "Lifecycle tests",
    snapshotRequest: { throw LifecycleTestError.unexpectedCall },
    snapshotSubscription: { [unowned self] _ in
      AsyncThrowingStream { self.streams.append($0) }
    },
    sleep: { [unowned self] _ in
      try await withTaskCancellationHandler {
        try await self.delay.wait()
      } onCancel: {
        Task { @MainActor [self] in self.cancellations += 1 }
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
    let disconnect = start { [self] in await session.disconnect() }
    delay.finish()
    streams.forEach { $0.finish() }
    try await disconnect.join()
    try await eventually("bridge stop operations drained") { operations.allSatisfy(\.done) }
  }
}

extension MobileLifecycleTests {
  func testReconnectWaitingForOldRunCannotUndoLaterDisconnect() async throws {
    let f = BridgeStopFixture()
    addTeardownBlock { @MainActor in try await f.finish() }
    f.session.connect()
    try await eventually("initial subscription") { f.streams.count == 1 }
    f.streams[0].yield(FleetSnapshot(revision: 90, devices: []))
    try await eventually("connected revision") { f.session.snapshot?.revision == 90 }
    f.streams[0].finish(throwing: LifecycleTestError.dropped)
    try await eventually("retry suspended") { f.delay.count == 1 }
    XCTAssertTrue(f.session.state.isConnected)
    let reconnecting = f.start { await f.session.reconnect() }
    try await eventually("reconnect entered old disconnect") { f.cancellations == 1 }
    try await f.start { await f.session.disconnect() }.join()
    XCTAssertEqual(f.session.state, .idle)
    f.delay.resolve(0, .success(()))
    try await reconnecting.join()
    XCTAssertEqual(f.session.state, .idle,
      "Completion of an older reconnect must not undo the latest explicit disconnect")
    XCTAssertEqual(f.session.snapshot?.revision, 90)
  }
}

private final class ResumeTransport: MobileTransport, @unchecked Sendable {
  let base: DirectTransportFixture
  @MainActor let pings = Suspensions<JSONValue>("resume ping")
  @MainActor var holdPing = false
  @MainActor let closing = Suspensions<Void>("direct reconnect close")
  @MainActor var holdClose = false
  init(_ label: String) { base = DirectTransportFixture(label) }
  @MainActor func request(method: String, params: JSONValue) async throws -> JSONValue {
    if method == "ping", holdPing { return try await pings.wait() }
    return try await base.request(method: method, params: params)
  }
  func events(kinds: [String], statusPaneIDs: [String]) -> AsyncThrowingStream<HerdrEvent, Error> {
    base.events(kinds: kinds, statusPaneIDs: statusPaneIDs)
  }
  func openTerminalSession(
    target: TerminalAttachTarget, mode: TerminalSessionMode, size: TerminalSize
  ) async throws -> any TerminalSession { throw LifecycleTestError.unexpectedCall }
  func stageAttachment(_ attachment: MobileAttachmentPayload) async throws -> String {
    throw LifecycleTestError.unexpectedCall
  }
  func readFileRange(path: String, offset: Int64, limit: Int) async throws -> FileRangeRead {
    throw LifecycleTestError.unexpectedCall
  }
  @MainActor func close() async {
    await base.close()
    if holdClose { try? await closing.wait() }
  }
  @MainActor func finish() {
    holdClose = false
    closing.finish()
    pings.finish()
    base.finish()
  }
}

@MainActor
private final class DirectBoundaryFixture {
  let transports = (1...4).map { ResumeTransport("boundary-\($0)") }
  let debounce = Suspensions<Void>("boundary debounce")
  let retry = Suspensions<Void>("boundary retry")
  var opens = 0
  var changes = 0
  var operations: [LifecycleOperation] = []
  lazy var session = MobileDeviceSession(
    device: MobileDevice(name: "Synthetic direct device", host: "invalid.example"),
    openTransport: { [unowned self] _ in
      self.opens += 1
      guard self.opens <= self.transports.count else { throw LifecycleTestError.unexpectedCall }
      return self.transports[self.opens - 1]
    },
    sleep: { [unowned self] duration in
      if duration == .milliseconds(300) {
        try await self.debounce.wait()
      } else {
        try await self.retry.wait()
      }
    }
  )
  func start(_ body: @escaping @MainActor () async -> Void) -> LifecycleOperation {
    let operation = LifecycleOperation(body)
    operations.append(operation)
    return operation
  }
  func connect() async throws {
    session.onChange = { [weak self] in self?.changes += 1 }
    try await start { [self] in await session.connect() }.join()
    XCTAssertEqual(session.snapshot?.version, "boundary-1")
  }
  func finish() async throws {
    operations.forEach { $0.task?.cancel() }
    let disconnect = start { [self] in await session.disconnect() }
    transports.forEach { $0.finish() }
    debounce.finish()
    retry.finish()
    try await disconnect.join()
    try await eventually("direct boundary operations drained") { operations.allSatisfy(\.done) }
  }
}

extension MobileLifecycleTests {
  private func boundaryFixture() -> DirectBoundaryFixture {
    let f = DirectBoundaryFixture()
    addTeardownBlock { @MainActor in try await f.finish() }
    return f
  }

  func testDelayedReconnectCloseCannotUndoLaterDisconnect() async throws {
    let f = boundaryFixture()
    try await f.connect()
    let first = f.transports[0]
    first.holdClose = true
    let reconnecting = f.start { await f.session.reconnect() }
    try await eventually("reconnect suspended in old transport close") { first.closing.count == 1 }
    XCTAssertNil(f.session.transport)

    try await f.start { await f.session.disconnect() }.join()
    XCTAssertEqual(f.session.state, .idle)
    let changesAfterLatestDisconnect = f.changes

    first.closing.resolve(0, .success(()))
    try await reconnecting.join()
    XCTAssertEqual(f.session.state, .idle,
      "An old direct reconnect must not undo a later explicit disconnect")
    XCTAssertNil(f.session.transport)
    XCTAssertEqual(f.opens, 1, "Superseded reconnect must not open a replacement transport")
    XCTAssertEqual(f.session.snapshot?.version, "boundary-1")
    XCTAssertEqual(f.changes, changesAfterLatestDisconnect)
    XCTAssertEqual(first.base.closes, 1)
    XCTAssertEqual(f.transports[1].base.requests, 0)
  }

  func testCancelledReconnectDuringCloseDoesNotOpenReplacement() async throws {
    let f = boundaryFixture()
    try await f.connect()
    let first = f.transports[0]
    first.holdClose = true
    let reconnecting = f.start { await f.session.reconnect() }
    try await eventually("cancel target suspended in old transport close") { first.closing.count == 1 }
    reconnecting.task?.cancel()

    first.closing.resolve(0, .success(()))
    try await reconnecting.join()
    XCTAssertEqual(first.closing.completionWasCancelled[0], true)
    XCTAssertEqual(f.session.state, .idle,
      "Cancellation during disconnect must not leave a new connection attempt marked connecting")
    XCTAssertNil(f.session.transport)
    XCTAssertEqual(f.opens, 1, "Cancelled reconnect must not begin new transport I/O")
    XCTAssertEqual(f.session.snapshot?.version, "boundary-1")
    XCTAssertEqual(first.base.closes, 1)
    XCTAssertEqual(f.transports[1].base.requests, 0)
  }

  func testLateResumePingFailureCannotReconnectAfterDisconnectOrReplaceNewGeneration() async throws {
    for replaceConnection in [false, true] {
      let f = boundaryFixture()
      try await f.connect()
      let first = f.transports[0]
      first.holdPing = true
      let resuming = f.start { await f.session.resume() }
      try await eventually("resume ping suspended") { first.pings.count == 1 }
      if replaceConnection {
        try await f.start { await f.session.reconnect() }.join()
        XCTAssertEqual(f.session.snapshot?.version, "boundary-2")
      } else {
        try await f.start { await f.session.disconnect() }.join()
        XCTAssertEqual(f.session.state, .idle)
      }
      first.pings.resolve(0, .failure(LifecycleTestError.dropped))
      try await resuming.join()
      XCTAssertEqual(f.opens, replaceConnection ? 2 : 1,
        "A ping from a retired generation must not open another connection")
      if replaceConnection {
        XCTAssertEqual(f.session.state, .connected(version: "boundary-2"))
        XCTAssertEqual(f.session.snapshot?.version, "boundary-2")
        XCTAssertEqual(f.transports[1].base.closes, 0)
      } else {
        XCTAssertEqual(f.session.state, .idle)
        XCTAssertNil(f.session.transport)
      }
    }
  }

  func testLateResumePingSuccessCannotRefreshReplacementConnection() async throws {
    let f = boundaryFixture()
    try await f.connect()
    let first = f.transports[0]
    first.holdPing = true
    let resuming = f.start { await f.session.resume() }
    try await eventually("resume ping suspended") { first.pings.count == 1 }
    try await f.start { await f.session.reconnect() }.join()
    XCTAssertEqual(f.transports[1].base.requests, 1)
    first.pings.resolve(0, .success(.object([
      "version": .string("obsolete"), "protocol": .number(22)
    ])))
    try await resuming.join()
    XCTAssertEqual(f.transports[1].base.requests, 1,
      "Retired resume success must not schedule a refresh on the replacement transport")
    XCTAssertEqual(f.opens, 2)
    XCTAssertEqual(f.session.state, .connected(version: "boundary-2"))
    XCTAssertEqual(f.session.snapshot?.version, "boundary-2")
    XCTAssertEqual(f.transports[1].base.closes, 0)
  }

  // Read-only task inspection supplies an exact completion barrier for the
  // cancellation-insensitive retry, without adding a production testing API.
  private func reconnectTask(_ session: MobileDeviceSession) throws -> Task<Void, Never> {
    let child = try XCTUnwrap(Mirror(reflecting: session).children.first { $0.label == "reconnectTask" })
    return try XCTUnwrap(child.value as? Task<Void, Never>, "Expected a live production reconnect task")
  }

  func testCancelledReconnectCleanupCannotLoseReplacementRetryOwnership() async throws {
    let f = boundaryFixture()
    try await f.connect()
    f.transports[0].base.drop()
    try await eventually("first automatic retry pending") { f.retry.count == 1 }
    let oldReconnect = try reconnectTask(f.session)
    f.transports[1].base.holdSnapshots = true
    f.retry.resolve(0, .success(()))
    try await eventually("first retry initial snapshot suspended") {
      f.transports[1].base.replies.count == 1
    }
    try await f.start { await f.session.reconnect() }.join()
    XCTAssertTrue(oldReconnect.isCancelled)
    XCTAssertEqual(f.session.snapshot?.version, "boundary-3")
    f.transports[2].base.drop()
    try await eventually("replacement retry pending") { f.retry.count == 2 }
    let replacementRetry = try reconnectTask(f.session)
    f.transports[1].base.replies.resolve(0, .success(snapshotReply("obsolete retry")))
    try await f.start { await oldReconnect.value }.join()
    XCTAssertEqual(f.session.snapshot?.version, "boundary-3")
    try await f.start { await f.session.disconnect() }.join()
    XCTAssertTrue(replacementRetry.isCancelled,
      "Old reconnect cleanup must not erase the handle needed to cancel the replacement retry")
    f.retry.resolve(1, .success(()))
    try await f.start { await replacementRetry.value }.join()
    XCTAssertEqual(f.opens, 3, "A detached retry must not reopen after explicit disconnect")
    XCTAssertEqual(f.session.state, .idle)
    XCTAssertNil(f.session.transport)
  }
}
