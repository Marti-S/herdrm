import Foundation
import HerdrKit

/// Immutable, revision-scoped lookup tables for the mobile fleet UI.
/// Building these once avoids repeated fleet-wide flattening, filtering, and
/// linear rank searches during a single SwiftUI update cycle.
struct MobileFleetIndex {
  private struct TabKey: Hashable {
    let deviceID: UUID
    let tabID: String
  }

  static let empty = MobileFleetIndex(devices: [])

  let devices: [MobileDeviceEntry]
  let devicesByID: [UUID: MobileDeviceEntry]
  let snapshotsByDeviceID: [UUID: SessionSnapshot]

  let spaces: [MobileSpaceEntry]
  let spacesByDeviceID: [UUID: [MobileSpaceEntry]]
  let workspacesByRef: [FleetSpaceRef: WorkspaceInfo]

  let agents: [MobileAgentEntry]
  let agentsByDeviceID: [UUID: [MobileAgentEntry]]
  let agentsBySpaceRef: [FleetSpaceRef: [MobileAgentEntry]]
  let agentsByRef: [FleetPaneRef: MobileAgentEntry]

  let terminals: [MobileTerminalEntry]
  let terminalsByDeviceID: [UUID: [MobileTerminalEntry]]
  let terminalsBySpaceRef: [FleetSpaceRef: [MobileTerminalEntry]]
  let terminalsByRef: [FleetPaneRef: MobileTerminalEntry]

  private let tabLabelsByKey: [TabKey: String]

  init(devices: [MobileDeviceEntry]) {
    self.devices = devices

    var devicesByID: [UUID: MobileDeviceEntry] = [:]
    var snapshotsByDeviceID: [UUID: SessionSnapshot] = [:]
    var deviceRanks: [UUID: Int] = [:]
    var workspaceRanks: [FleetSpaceRef: Int] = [:]
    var tabRanks: [TabKey: Int] = [:]
    var tabLabelsByKey: [TabKey: String] = [:]
    var workspacesByRef: [FleetSpaceRef: WorkspaceInfo] = [:]
    var spaces: [MobileSpaceEntry] = []
    var unsortedAgents: [MobileAgentEntry] = []
    var terminals: [MobileTerminalEntry] = []

    for (deviceRank, device) in devices.enumerated() {
      if devicesByID[device.id] == nil {
        devicesByID[device.id] = device
        deviceRanks[device.id] = deviceRank
      }
      guard let snapshot = device.snapshot else { continue }
      if snapshotsByDeviceID[device.id] == nil {
        snapshotsByDeviceID[device.id] = snapshot
      }

      for (workspaceRank, workspace) in snapshot.workspaces.enumerated() {
        let ref = FleetSpaceRef(
          deviceID: device.id,
          workspaceID: workspace.workspaceID
        )
        if workspacesByRef[ref] == nil {
          workspacesByRef[ref] = workspace
          workspaceRanks[ref] = workspaceRank
          spaces.append(MobileSpaceEntry(
            ref: ref,
            workspace: workspace,
            device: device
          ))
        }
      }

      for (tabRank, tab) in (snapshot.tabs ?? []).enumerated() {
        let key = TabKey(deviceID: device.id, tabID: tab.tabID)
        if tabRanks[key] == nil {
          tabRanks[key] = tabRank
          if let label = tab.customLabel {
            tabLabelsByKey[key] = label
          }
        }
      }

      for agent in snapshot.agents {
        let ref = FleetPaneRef(deviceID: device.id, paneID: agent.paneID)
        unsortedAgents.append(MobileAgentEntry(
          ref: ref,
          agent: agent,
          device: device
        ))
      }

      for pane in snapshot.ordinaryTerminalPanes {
        let ref = FleetPaneRef(deviceID: device.id, paneID: pane.paneID)
        terminals.append(MobileTerminalEntry(
          ref: ref,
          pane: pane,
          device: device
        ))
      }
    }

    let agents = unsortedAgents.enumerated().sorted { lhs, rhs in
      let left = lhs.element
      let right = rhs.element
      if left.agent.status.sortBucket != right.agent.status.sortBucket {
        return left.agent.status.sortBucket < right.agent.status.sortBucket
      }
      let leftDevice = deviceRanks[left.ref.deviceID] ?? Int.max
      let rightDevice = deviceRanks[right.ref.deviceID] ?? Int.max
      if leftDevice != rightDevice { return leftDevice < rightDevice }
      let leftWorkspace = workspaceRanks[FleetSpaceRef(
        deviceID: left.ref.deviceID,
        workspaceID: left.agent.workspaceID
      )] ?? Int.max
      let rightWorkspace = workspaceRanks[FleetSpaceRef(
        deviceID: right.ref.deviceID,
        workspaceID: right.agent.workspaceID
      )] ?? Int.max
      if leftWorkspace != rightWorkspace { return leftWorkspace < rightWorkspace }
      let leftTab = tabRanks[TabKey(
        deviceID: left.ref.deviceID,
        tabID: left.agent.tabID
      )] ?? Int.max
      let rightTab = tabRanks[TabKey(
        deviceID: right.ref.deviceID,
        tabID: right.agent.tabID
      )] ?? Int.max
      if leftTab != rightTab { return leftTab < rightTab }
      return lhs.offset < rhs.offset
    }.map(\.element)

    var agentsByRef: [FleetPaneRef: MobileAgentEntry] = [:]
    for entry in agents where agentsByRef[entry.ref] == nil {
      agentsByRef[entry.ref] = entry
    }
    var terminalsByRef: [FleetPaneRef: MobileTerminalEntry] = [:]
    for entry in terminals where terminalsByRef[entry.ref] == nil {
      terminalsByRef[entry.ref] = entry
    }

    self.devicesByID = devicesByID
    self.snapshotsByDeviceID = snapshotsByDeviceID
    self.spaces = spaces
    self.spacesByDeviceID = Dictionary(grouping: spaces, by: { $0.ref.deviceID })
    self.workspacesByRef = workspacesByRef
    self.agents = agents
    self.agentsByDeviceID = Dictionary(grouping: agents, by: { $0.ref.deviceID })
    self.agentsBySpaceRef = Dictionary(grouping: agents, by: {
      FleetSpaceRef(
        deviceID: $0.ref.deviceID,
        workspaceID: $0.agent.workspaceID
      )
    })
    self.agentsByRef = agentsByRef
    self.terminals = terminals
    self.terminalsByDeviceID = Dictionary(grouping: terminals, by: { $0.ref.deviceID })
    self.terminalsBySpaceRef = Dictionary(grouping: terminals, by: {
      FleetSpaceRef(
        deviceID: $0.ref.deviceID,
        workspaceID: $0.pane.workspaceID
      )
    })
    self.terminalsByRef = terminalsByRef
    self.tabLabelsByKey = tabLabelsByKey
  }

  func tabLabel(deviceID: UUID, tabID: String) -> String? {
    tabLabelsByKey[TabKey(deviceID: deviceID, tabID: tabID)]
  }

  func spaceName(deviceID: UUID, workspaceID: String) -> String {
    workspacesByRef[FleetSpaceRef(
      deviceID: deviceID,
      workspaceID: workspaceID
    )]?.label ?? workspaceID
  }
}
