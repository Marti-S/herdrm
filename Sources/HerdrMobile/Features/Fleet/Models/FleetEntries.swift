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
