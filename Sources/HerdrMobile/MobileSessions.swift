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
  private var refreshPending = false
  private var generation: UInt64 = 0

  var onChange: (() -> Void)?

  init(device: MobileDevice) {
    self.device = device
  }

  func reconnect() async {
    await disconnect()
    await connect()
  }

  func connect() async {
    switch state {
    case .connecting, .connected:
      return
    case .idle, .failed:
      break
    }

    generation &+= 1
    let expectedGeneration = generation
    eventTask?.cancel()
    eventTask = nil
    if let stale = transport {
      transport = nil
      await stale.close()
    }
    guard generation == expectedGeneration else { return }

    state = .connecting
    onChange?()
    var candidate: SSHDirectTransport?
    do {
      let opened = try await SSHDirectTransport.connect(device: device)
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
      await refresh(generation: expectedGeneration)
      guard generation == expectedGeneration else { return }
      startEventPump(transport: opened, generation: expectedGeneration)
    } catch {
      if let candidate { await candidate.close() }
      guard generation == expectedGeneration else { return }
      state = .failed(Self.presentation(error))
    }
    onChange?()
  }

  func disconnect() async {
    generation &+= 1
    let expectedGeneration = generation
    eventTask?.cancel()
    eventTask = nil
    let stale = transport
    transport = nil
    await stale?.close()
    guard generation == expectedGeneration else { return }
    state = .idle
    onChange?()
  }

  func refresh() async {
    await refresh(generation: nil)
  }

  private func refresh(generation expectedGeneration: UInt64?) async {
    guard let transport else { return }
    struct Envelope: Codable { let snapshot: SessionSnapshot }
    do {
      let next = try await transport.request(
        method: "session.snapshot", as: Envelope.self
      ).snapshot
      if let expectedGeneration, generation != expectedGeneration { return }
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
        for try await _ in transport.events(kinds: HerdrEvent.allKinds) {
          await self?.scheduleRefresh(generation: expectedGeneration)
        }
      } catch {}
      guard
        let self,
        !Task.isCancelled,
        self.generation == expectedGeneration
      else { return }
      if case .connected = self.state {
        self.state = .failed(String(localized: "Connection lost"))
        let stale = self.transport
        self.transport = nil
        await stale?.close()
        guard self.generation == expectedGeneration else { return }
        self.onChange?()
      }
    }
  }

  private func scheduleRefresh(generation expectedGeneration: UInt64) async {
    guard generation == expectedGeneration, !refreshPending else { return }
    refreshPending = true
    try? await Task.sleep(for: .milliseconds(300))
    refreshPending = false
    guard generation == expectedGeneration else { return }
    await refresh(generation: expectedGeneration)
  }

  private static func presentation(_ error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(error)"
  }
}
