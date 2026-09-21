import Foundation
import HerdrKit
import XCTest

enum LifecycleTestError: Error {
  case dropped
  case timeout(String)
  case unexpectedCall
}

/// All observations have a deadline, including fixture continuations. Cleanup
/// resumes pending I/O rather than joining cancellation-insensitive tasks.
@MainActor
func eventually(
  _ message: String,
  timeout: Duration = .seconds(3),
  file: StaticString = #filePath,
  line: UInt = #line,
  _ condition: () -> Bool
) async throws {
  try await waitForFixture(message, timeout: timeout, file: file, line: line, condition)
}

@MainActor
final class Suspensions<Value> {
  private(set) var count = 0
  private(set) var completionWasCancelled: [Int: Bool] = [:]
  private var pending: [Int: CheckedContinuation<Value, Error>] = [:]
  private var deadlines: [Int: Task<Void, Never>] = [:]
  private var finished = false
  let name: String

  init(_ name: String) { self.name = name }

  // Intentionally ignores cancellation to exercise late transport completions.
  func wait() async throws -> Value {
    guard !finished else { throw CancellationError() }
    let index = count
    count += 1
    defer { completionWasCancelled[index] = Task.isCancelled }
    return try await withCheckedThrowingContinuation { continuation in
      pending[index] = continuation
      deadlines[index] = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        guard let self, self.pending[index] != nil else { return }
        XCTFail("Unreleased fixture: \(self.name)[\(index)]")
        self.resolve(index, .failure(LifecycleTestError.timeout(self.name)))
      }
    }
  }

  func resolve(_ index: Int, _ result: Result<Value, Error>) {
    deadlines.removeValue(forKey: index)?.cancel()
    pending.removeValue(forKey: index)?.resume(with: result)
  }

  func finish() {
    finished = true
    for index in Array(pending.keys) { resolve(index, .failure(CancellationError())) }
  }
}

@MainActor
final class LifecycleOperation {
  private(set) var done = false
  var task: Task<Void, Never>?

  init(_ body: @escaping @MainActor () async -> Void) {
    task = Task { [weak self] in
      await body()
      self?.done = true
    }
  }

  func join(
    timeout: Duration = .seconds(3), file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    try await eventually("operation completion", timeout: timeout, file: file, line: line) { done }
  }
}

@MainActor
final class BridgeFixture {
  let requests = Suspensions<FleetSnapshot>("bridge refresh")
  let delays = Suspensions<Void>("bridge retry")
  private(set) var streams: [AsyncThrowingStream<FleetSnapshot, Error>.Continuation] = []
  private(set) var afterRevisions: [UInt64?] = []
  private(set) var changes = 0
  var operations: [LifecycleOperation] = []
  lazy var session = MobileBridgeSession(
    bridge: MobileBridge(name: "Synthetic bridge", host: "invalid.example"),
    clientID: UUID(), clientName: "Lifecycle tests",
    snapshotRequest: { [unowned self] in try await self.requests.wait() },
    snapshotSubscription: { [unowned self] revision in
      self.afterRevisions.append(revision)
      return AsyncThrowingStream { self.streams.append($0) }
    },
    sleep: { [unowned self] _ in try await self.delays.wait() }
  )

  func connect(revision: UInt64 = 90) async throws {
    session.onChange = { [weak self] in self?.changes += 1 }
    session.connect()
    try await eventually("first bridge subscription") { streams.count == 1 }
    try await send(revision, on: 0)
  }

  func send(_ revision: UInt64, on stream: Int) async throws {
    streams[stream].yield(FleetSnapshot(revision: revision, devices: []))
    try await eventually("bridge revision \(revision)") { session.snapshot?.revision == revision }
  }

  func start(_ body: @escaping @MainActor () async -> Void) -> LifecycleOperation {
    let operation = LifecycleOperation(body)
    operations.append(operation)
    return operation
  }

  func refresh() async throws -> LifecycleOperation {
    let count = requests.count
    let operation = start { [self] in await session.refresh() }
    try await eventually("bridge refresh started") { requests.count == count + 1 }
    return operation
  }

  func retry() async throws {
    let count = streams.count
    let delay = delays.count
    streams[count - 1].finish(throwing: LifecycleTestError.dropped)
    try await eventually("bridge backoff") { delays.count == delay + 1 }
    XCTAssertTrue(session.state.isConnected, "Grace period must keep connected state")
    delays.resolve(delay, .success(()))
    try await eventually("replacement bridge subscription") { streams.count == count + 1 }
  }

  func finish(timeout: Duration = .seconds(3)) async throws {
    operations.forEach { $0.task?.cancel() }
    let disconnect = start { [self] in await session.disconnect() }
    requests.finish()
    delays.finish()
    streams.forEach { $0.finish() }
    // Bounded observation, never task.value: even broken cancellation cannot
    // hang teardown or leave an untracked disconnect running into the next test.
    try await disconnect.join(timeout: timeout)
    try await eventually("bridge operations drained", timeout: timeout) { operations.allSatisfy(\.done) }
  }
}

/// Mutable fixture state is main-actor owned. The synchronous Sendable event
/// entrypoint uses a pre-created stream and never accesses that mutable state.
final class DirectTransportFixture: MobileTransport, @unchecked Sendable {
  let stream: AsyncThrowingStream<HerdrEvent, Error>
  let eventsContinuation: AsyncThrowingStream<HerdrEvent, Error>.Continuation
  @MainActor let replies = Suspensions<JSONValue>("direct snapshot")
  @MainActor let pings = Suspensions<JSONValue>("direct ping")
  @MainActor var holdPing = false
  @MainActor private(set) var requests = 0
  @MainActor private(set) var closes = 0
  @MainActor var holdSnapshots = false
  let label: String

  init(_ label: String) {
    self.label = label
    (stream, eventsContinuation) = AsyncThrowingStream.makeStream()
  }

  @MainActor
  func request(method: String, params: JSONValue) async throws -> JSONValue {
    switch method {
    case "ping":
      if holdPing { return try await pings.wait() }
      return .object(["version": .string(label), "protocol": .number(22)])
    case "session.snapshot":
      requests += 1
      if holdSnapshots { return try await replies.wait() }
      return snapshotReply(label)
    default: throw LifecycleTestError.unexpectedCall
    }
  }

  func events(kinds: [String], statusPaneIDs: [String]) -> AsyncThrowingStream<HerdrEvent, Error> {
    stream
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
  @MainActor func close() async { closes += 1 }

  func event() {
    eventsContinuation.yield(HerdrEvent(kind: "workspace.updated", payload: .object([:])))
  }
  func drop() { eventsContinuation.finish(throwing: LifecycleTestError.dropped) }
  @MainActor func finish() {
    pings.finish()
    replies.finish()
    eventsContinuation.finish()
  }
}

func snapshotReply(_ label: String) -> JSONValue {
  .object([
    "snapshot": .object([
      "agents": .array([]), "workspaces": .array([]), "version": .string(label),
    ])
  ])
}

@MainActor
final class DirectFixture {
  let first = DirectTransportFixture("connection-1")
  let second = DirectTransportFixture("connection-2")
  let debounce = Suspensions<Void>("direct debounce")
  let retryDelay = Suspensions<Void>("direct retry")
  private(set) var opens = 0
  var operations: [LifecycleOperation] = []
  lazy var session = MobileDeviceSession(
    device: MobileDevice(name: "Synthetic direct device"),
    openTransport: { [unowned self] _ in
      self.opens += 1
      guard self.opens <= 2 else { throw LifecycleTestError.unexpectedCall }
      return self.opens == 1 ? self.first : self.second
    },
    sleep: { [unowned self] duration in
      if duration == .milliseconds(300) {
        try await self.debounce.wait()
      } else {
        try await self.retryDelay.wait()
      }
    }
  )

  func start(_ body: @escaping @MainActor () async -> Void) -> LifecycleOperation {
    let operation = LifecycleOperation(body)
    operations.append(operation)
    return operation
  }

  func connect() async throws {
    try await start { [self] in await session.connect() }.join()
    XCTAssertEqual(session.snapshot?.version, "connection-1")
  }

  func dropAndRetry() async throws {
    first.drop()
    try await eventually("direct automatic retry backoff") { retryDelay.count == 1 }
    XCTAssertTrue(session.state.isConnected, "Grace period must retain connected state")
    XCTAssertEqual(first.closes, 1)
    retryDelay.resolve(0, .success(()))
    try await eventually("replacement transport opened") { opens == 2 }
  }

  func finish(timeout: Duration = .seconds(3)) async throws {
    operations.forEach { $0.task?.cancel() }
    let disconnect = start { [self] in await session.disconnect() }
    first.finish()
    second.finish()
    debounce.finish()
    retryDelay.finish()
    try await disconnect.join(timeout: timeout)
    try await eventually("direct operations drained", timeout: timeout) { operations.allSatisfy(\.done) }
  }
}
