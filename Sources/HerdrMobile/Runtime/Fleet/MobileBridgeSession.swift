import Foundation
import HerdrKit
import Security
import UIKit

/// Maintains the one long-lived fleet subscription. Per-device RPC and terminal
/// transports are stateless and open their own authenticated bridge connection.
@MainActor
final class MobileBridgeSession {
  let bridge: MobileBridge
  var state: MobileConnectionState = .idle
  private(set) var snapshot: FleetSnapshot?
  var onChange: (() -> Void)?

  private let clientID: UUID
  private let clientName: String
  private var runTask: Task<Void, Never>?
  private var generation: UInt64 = 0
  // Subscription retries do not change the outer run generation. Every attempt
  // has its own epoch, and revision ordering never depends on the displayed cache.
  private var connectionEpoch: UInt64 = 0
  private var acceptedRevision: UInt64?
  private var acceptedUpdate: UInt64 = 0
  private var refreshSequence: UInt64 = 0

  // Injectable I/O and delay boundaries; production still uses the authenticated client.
  private let snapshotRequest: (() async throws -> FleetSnapshot)?
  private let snapshotSubscription: ((UInt64?) throws -> AsyncThrowingStream<FleetSnapshot, Error>)?
  private let sleep: (Duration) async throws -> Void

  init(
    bridge: MobileBridge,
    clientID: UUID = MobileClientIdentity.id,
    clientName: String? = nil,
    snapshotRequest: (() async throws -> FleetSnapshot)? = nil,
    snapshotSubscription: ((UInt64?) throws -> AsyncThrowingStream<FleetSnapshot, Error>)? = nil,
    sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.bridge = bridge
    self.clientID = clientID
    self.clientName = clientName ?? MobileClientIdentity.name
    self.snapshotRequest = snapshotRequest
    self.snapshotSubscription = snapshotSubscription
    self.sleep = sleep
  }

  func reconnect() async {
    let expectedGeneration = generation &+ 1
    await disconnect()
    guard generation == expectedGeneration, !Task.isCancelled else { return }
    connect()
  }

  /// Scene became active: keep a live subscription and just refresh; only
  /// (re)connect when nothing is running or the last state was a failure.
  func resume() async {
    if runTask != nil, state.isConnected {
      await refresh()
      return
    }
    if runTask == nil {
      connect()
    }
  }

  func connect() {
    guard runTask == nil else { return }
    generation &+= 1
    advanceConnectionEpoch()
    let currentGeneration = generation
    state = .connecting
    onChange?()
    runTask = Task { [weak self] in
      await self?.runSubscriptionLoop(generation: currentGeneration)
    }
  }

  func disconnect() async {
    generation &+= 1
    let expectedGeneration = generation
    advanceConnectionEpoch()
    let task = runTask
    runTask = nil
    task?.cancel()
    await task?.value
    guard generation == expectedGeneration else { return }
    state = .idle
    onChange?()
  }

  func refresh() async {
    let epoch = connectionEpoch
    let update = acceptedUpdate
    refreshSequence &+= 1
    let request = refreshSequence
    do {
      let next: FleetSnapshot
      if let snapshotRequest {
        next = try await snapshotRequest()
      } else {
        next = try await makeClient().snapshot()
      }
      guard canAcceptRefresh(epoch: epoch, update: update, request: request) else { return }
      accept(next)
    } catch {
      guard canAcceptRefresh(epoch: epoch, update: update, request: request) else { return }
      let nextState = MobileConnectionState.failed(Self.presentation(error))
      guard state != nextState else { return }
      state = nextState
      onChange?()
    }
  }

  private func advanceConnectionEpoch() {
    connectionEpoch &+= 1
    acceptedRevision = nil
  }

  private func canAcceptRefresh(epoch: UInt64, update: UInt64, request: UInt64) -> Bool {
    !Task.isCancelled && connectionEpoch == epoch
      && acceptedUpdate == update && refreshSequence == request
  }

  private func accept(_ next: FleetSnapshot, firstOnConnection: Bool = false) {
    if !firstOnConnection, let acceptedRevision, next.revision < acceptedRevision { return }
    let previousState = state
    let snapshotChanged = (firstOnConnection || acceptedRevision != next.revision) && snapshot != next
    acceptedRevision = next.revision
    // Even an identical first snapshot establishes the new server's revision
    // sequence and invalidates refreshes begun before that handshake completed.
    acceptedUpdate &+= 1
    if snapshotChanged { snapshot = next }
    state = .connected(version: "Bridge \(FleetBridgeProtocol.version)")
    if snapshotChanged || state != previousState { onChange?() }
  }

  func transport(for deviceID: UUID) -> (any MobileTransport)? {
    guard snapshot?.device(deviceID) != nil,
      let client = try? makeClient()
    else { return nil }
    return FleetBridgeDeviceTransport(client: client, deviceID: deviceID)
  }

  /// A dropped subscription stays invisible for this long while the loop
  /// reconnects; Tailscale path changes recover well inside it.
  static let failureGrace: Duration = .seconds(8)

  private func runSubscriptionLoop(generation expectedGeneration: UInt64) async {
    var backoff: Double = 1
    var droppedAt: ContinuousClock.Instant?
    defer {
      if generation == expectedGeneration {
        runTask = nil
      }
    }

    while !Task.isCancelled, generation == expectedGeneration {
      advanceConnectionEpoch()
      // Within the grace window after a drop, keep showing the last good
      // state and snapshot rather than flashing "Connecting…".
      let withinGrace = droppedAt.map { $0.duration(to: .now) < Self.failureGrace } ?? false
      if !withinGrace, state != .connecting {
        state = .connecting
        onChange?()
      }
      do {
        var receivedSnapshotOnConnection = false
        let stream = try snapshotSubscription?(snapshot?.revision)
          ?? makeClient().snapshots(after: snapshot?.revision)
        for try await next in stream {
          guard
            !Task.isCancelled,
            generation == expectedGeneration
          else { return }

          // The first subscription snapshot is authoritative after a server
          // restart, including when a one-shot refresh arrived before it.
          accept(next, firstOnConnection: !receivedSnapshotOnConnection)
          receivedSnapshotOnConnection = true
          backoff = 1
          droppedAt = nil
        }
        guard
          !Task.isCancelled,
          generation == expectedGeneration
        else { return }
        throw FleetBridgeClientError.connectionClosed
      } catch {
        guard
          !Task.isCancelled,
          generation == expectedGeneration
        else { return }
        // Retire refreshes as soon as the stream drops, not only after backoff.
        advanceConnectionEpoch()
        let permanent = (error as? FleetBridgeClientError)?.isPermanent == true
        if state.isConnected, droppedAt == nil, !permanent {
          droppedAt = .now
        }
        let stillInGrace = droppedAt.map { $0.duration(to: .now) < Self.failureGrace } ?? false
        if permanent || !stillInGrace {
          state = .failed(Self.presentation(error))
          onChange?()
        }
        if permanent {
          return
        }
      }

      try? await sleep(.seconds(backoff))
      backoff = min(backoff * 2, 30)
    }
  }

  private func makeClient() throws -> FleetBridgeClient {
    guard let token = try MobileBridgeSecretStore.token(for: bridge.id),
      !token.isEmpty
    else { throw FleetBridgeClientError.missingToken }
    return FleetBridgeClient(
      bridge: bridge,
      token: token,
      clientID: clientID,
      clientName: clientName
    )
  }

  private static func presentation(_ error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(error)"
  }
}
