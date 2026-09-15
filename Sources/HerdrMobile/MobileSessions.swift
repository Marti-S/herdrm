import Foundation
import HerdrKit
import SwiftUI

/// Connection state shown by the iOS fleet UI.
enum MobileConnectionState: Equatable {
  case idle
  case connecting
  case connected(version: String)
  case failed(String)

  init(_ connection: FleetConnectionInfo) {
    switch connection.phase {
    case .idle: self = .idle
    case .connecting: self = .connecting
    case .connected: self = .connected(version: connection.version ?? "")
    case .failed: self = .failed(connection.message ?? String(localized: "Connection failed"))
    }
  }

  var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }
}

struct MobileDeviceEntry: Identifiable {
  enum Source: Equatable {
    case bridge
    case direct
  }

  let id: UUID
  let source: Source
  let name: String
  let subtitle: String
  let state: MobileConnectionState
  let snapshot: SessionSnapshot?
  let availableAgentKinds: [String]
}

struct MobileSpaceEntry: Identifiable {
  let ref: FleetSpaceRef
  let workspace: WorkspaceInfo
  let device: MobileDeviceEntry

  var id: FleetSpaceRef { ref }
}

struct MobileAgentEntry: Identifiable {
  let ref: FleetPaneRef
  let agent: AgentInfo
  let device: MobileDeviceEntry

  var id: FleetPaneRef { ref }
}

struct MobileTerminalEntry: Identifiable {
  let ref: FleetPaneRef
  let pane: PaneInfo
  let device: MobileDeviceEntry

  var id: FleetPaneRef { ref }
}

/// One direct-SSH device's live Herdr view. Bridge devices are maintained by
/// `MobileBridgeSession` as one Mac-owned fleet subscription instead.
@MainActor
final class MobileDeviceSession {
  let device: MobileDevice
  var state: MobileConnectionState = .idle
  var snapshot: SessionSnapshot?
  private(set) var transport: MobileTransport?
  private var eventTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var refreshTaskGeneration: UInt64 = 0
  private var refreshDirty = false
  private var generation: UInt64 = 0
  private var reconnectTask: Task<Void, Never>?

  /// How long a dropped transport may stay invisible while reconnecting.
  /// Tailscale path changes and a dozing Mac usually recover well inside
  /// this window, so the UI keeps the last snapshot instead of flashing
  /// "Connection lost" for a blip.
  static let failureGrace: Duration = .seconds(8)
  private static let reconnectBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]

  var onChange: (() -> Void)?

  init(device: MobileDevice) {
    self.device = device
  }

  func reconnect() async {
    await disconnect()
    await connect()
  }

  /// Scene became active. A healthy transport is kept and only verified;
  /// tearing it down on every activation is what made the sidebar flash
  /// "Connecting…" after Notification Center or Face ID.
  func resume() async {
    switch state {
    case .connected:
      guard let transport else { await reconnect(); return }
      do {
        _ = try await transport.request(method: "ping", params: .object([:]), as: PingResult.self)
        await requestRefresh(generation: generation, debounce: false)
      } catch {
        await reconnect()
      }
    case .connecting:
      return
    case .idle, .failed:
      await connect()
    }
  }

  func connect() async {
    switch state {
    case .connecting, .connected:
      return
    case .idle, .failed:
      break
    }

    do {
      try await establish(showConnecting: true)
    } catch {
      // establish() already published the failed state.
    }
  }

  /// Opens a fresh transport. With `showConnecting` false the previous
  /// `.connected` state is left untouched until the outcome is known, so a
  /// background reconnect does not flash through the sidebar.
  private func establish(showConnecting: Bool) async throws {
    generation &+= 1
    let expectedGeneration = generation
    eventTask?.cancel()
    eventTask = nil
    if let stale = transport {
      transport = nil
      await stale.close()
    }
    guard generation == expectedGeneration else { return }

    if showConnecting {
      state = .connecting
      onChange?()
    }
    var candidate: (any MobileTransport)?
    do {
      let opened: any MobileTransport
      switch device.kind {
      case .ssh:
        opened = try await SSHDirectTransport.connect(device: device)
      case .tailcat:
        // Control plane only: the tunnel re-serves herdr's API socket
        // locally, so RPC and events work and terminal attach throws.
        opened = try await TailcatMobileTransport.connect(device: device)
      }
      candidate = opened
      let pong = try await opened.request(
        method: "ping", params: .object([:]), as: PingResult.self
      )
      guard pong.protocolVersion >= 17 else {
        throw HerdrError.incompatibleProtocol(pong.protocolVersion)
      }
      guard
        generation == expectedGeneration,
        !Task.isCancelled
      else {
        await opened.close()
        return
      }
      transport = opened
      candidate = nil
      state = .connected(version: pong.version)
      await requestRefresh(generation: expectedGeneration, debounce: false)
      guard generation == expectedGeneration else { return }
      startEventPump(transport: opened, generation: expectedGeneration)
    } catch {
      if let candidate { await candidate.close() }
      guard generation == expectedGeneration else { throw error }
      if showConnecting {
        state = .failed(Self.presentation(error))
        onChange?()
      }
      throw error
    }
    onChange?()
  }

  func disconnect() async {
    generation &+= 1
    let expectedGeneration = generation
    reconnectTask?.cancel()
    reconnectTask = nil
    eventTask?.cancel()
    eventTask = nil
    refreshTaskGeneration &+= 1
    refreshTask?.cancel()
    refreshTask = nil
    refreshDirty = false
    let stale = transport
    transport = nil
    await stale?.close()
    guard generation == expectedGeneration else { return }
    state = .idle
    onChange?()
  }

  func refresh() async {
    await requestRefresh(generation: generation, debounce: false)
  }

  private func requestRefresh(
    generation expectedGeneration: UInt64,
    debounce: Bool
  ) async {
    guard generation == expectedGeneration else { return }
    refreshDirty = true
    let task = refreshTask
      ?? startRefreshTask(generation: expectedGeneration, debounce: debounce)
    await task.value
  }

  private func startRefreshTask(
    generation expectedGeneration: UInt64,
    debounce: Bool
  ) -> Task<Void, Never> {
    refreshTaskGeneration &+= 1
    let taskGeneration = refreshTaskGeneration
    let task = Task { [weak self] in
      if debounce {
        try? await Task.sleep(for: .milliseconds(300))
      }
      guard let self, !Task.isCancelled else { return }
      await self.runRefreshLoop(
        generation: expectedGeneration,
        taskGeneration: taskGeneration
      )
    }
    refreshTask = task
    return task
  }

  private func runRefreshLoop(
    generation expectedGeneration: UInt64,
    taskGeneration: UInt64
  ) async {
    while !Task.isCancelled,
      generation == expectedGeneration,
      refreshDirty
    {
      refreshDirty = false
      await performRefresh(generation: expectedGeneration)
    }
    if refreshTaskGeneration == taskGeneration {
      refreshTask = nil
    }
  }

  private func performRefresh(generation expectedGeneration: UInt64) async {
    guard let transport else { return }
    struct Envelope: Codable { let snapshot: SessionSnapshot }
    do {
      let next = try await transport.request(
        method: "session.snapshot", as: Envelope.self
      ).snapshot
      guard generation == expectedGeneration else { return }
      guard snapshot != next else { return }
      snapshot = next
      onChange?()
    } catch {
      // Keep the last snapshot. The event pump decides when the transport
      // has actually gone away.
    }
  }

  private func startEventPump(
    transport: any MobileTransport,
    generation expectedGeneration: UInt64
  ) {
    eventTask?.cancel()
    eventTask = Task { [weak self] in
      do {
        // herdr 0.9.0 scopes `pane.agent_status_changed` per pane, so the
        // subscription is re-armed whenever pane topology moves the set.
        eventSubscriptions: while !Task.isCancelled {
          guard let self, self.generation == expectedGeneration else { return }
          let subscribedPaneIDs = self.statusSubscriptionPaneIDs
          var needsResubscribe = false
          for try await event in transport.events(
            kinds: HerdrEvent.allKinds,
            statusPaneIDs: subscribedPaneIDs
          ) {
            guard !Task.isCancelled, self.generation == expectedGeneration else { return }
            if event.kind == HerdrEvent.agentStatusChangedKind {
              // Apply the status in place so the sidebar turns immediately;
              // the debounced snapshot still reconciles everything else.
              _ = self.applyAgentStatusEvent(event)
              self.scheduleRefresh(generation: expectedGeneration)
              continue
            }
            if event.kind == HerdrEvent.subscriptionStartedKind
              || Self.paneTopologyEventKinds.contains(event.kind)
            {
              // The pane set decides the subscription, so this snapshot is
              // fetched eagerly rather than debounced.
              await self.requestRefresh(generation: expectedGeneration, debounce: false)
              guard self.generation == expectedGeneration else { return }
              if self.statusSubscriptionPaneIDs != subscribedPaneIDs {
                needsResubscribe = true
                break
              }
              continue
            }
            self.scheduleRefresh(generation: expectedGeneration)
          }
          guard needsResubscribe, !Task.isCancelled else { break eventSubscriptions }
          try? await Task.sleep(for: .milliseconds(100))
        }
      } catch {}
      guard
        let self,
        !Task.isCancelled,
        self.generation == expectedGeneration
      else { return }
      if case .connected = self.state {
        let stale = self.transport
        self.transport = nil
        await stale?.close()
        guard self.generation == expectedGeneration else { return }
        self.scheduleReconnect()
      }
    }
  }

  /// Every pane herdr must report status for. Scoped subscriptions only fire
  /// for panes named here, so this is recomputed from each new snapshot.
  private var statusSubscriptionPaneIDs: [String] {
    guard let snapshot else { return [] }
    return Array(Set(
      snapshot.agents.map(\.paneID)
        + snapshot.ordinaryTerminalPanes.map(\.paneID)
    )).sorted()
  }

  @discardableResult
  private func applyAgentStatusEvent(_ event: HerdrEvent) -> Bool {
    guard let paneID = event.payload["data"]?["pane_id"]?.stringValue,
          let statusRaw = event.payload["data"]?["agent_status"]?.stringValue,
          let updated = snapshot?.updatingAgentStatus(
            paneID: paneID,
            status: AgentStatus(wire: statusRaw)
          )
    else { return false }
    snapshot = updated
    onChange?()
    return true
  }

  private static let paneTopologyEventKinds: Set<String> = [
    "pane.created",
    "pane.closed",
    "pane.moved",
    "pane.agent_detected",
  ]

  /// Transport dropped while connected: keep the snapshot and state, retry
  /// with backoff, and surface a failure only after `failureGrace`.
  private func scheduleReconnect() {
    reconnectTask?.cancel()
    reconnectTask = Task { [weak self] in
      guard let self else { return }
      let startedAt = ContinuousClock.now
      var attempt = 0
      var lastError: (any Error)?
      while !Task.isCancelled {
        let delay = Self.reconnectBackoff[min(attempt, Self.reconnectBackoff.count - 1)]
        attempt += 1
        do { try await Task.sleep(for: delay) } catch { return }
        guard !Task.isCancelled else { return }

        if startedAt.duration(to: .now) > Self.failureGrace, lastError != nil,
           case .connected = state {
          state = .failed(String(localized: "Connection lost"))
          onChange?()
        }

        do {
          try await establish(showConnecting: !state.isConnected)
          reconnectTask = nil
          return
        } catch is CancellationError {
          return
        } catch {
          lastError = error
        }
      }
    }
  }

  private func scheduleRefresh(generation expectedGeneration: UInt64) {
    guard generation == expectedGeneration else { return }
    refreshDirty = true
    guard refreshTask == nil else { return }
    _ = startRefreshTask(generation: expectedGeneration, debounce: true)
  }

  private static func presentation(_ error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(error)"
  }
}
