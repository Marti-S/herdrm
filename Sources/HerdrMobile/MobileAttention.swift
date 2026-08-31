import Foundation
import HerdrKit
import Observation

/// Client-local attention state. Herdr owns lifecycle status; the mobile UI
/// owns whether a finished Agent has been viewed on this device.
@MainActor
@Observable
final class MobileAttentionController {
  private(set) var unreadAgents: Set<AgentUnreadKey> = []
  private var previousStatuses: [UUID: [String: AgentStatus]] = [:]

  func process(model: MobileAppModel) {
    let devices = model.deviceEntries
    let liveDeviceIDs = Set(devices.map(\.id))

    previousStatuses = previousStatuses.filter { liveDeviceIDs.contains($0.key) }
    unreadAgents = Set(unreadAgents.filter { liveDeviceIDs.contains($0.deviceID) })

    for device in devices {
      guard let snapshot = device.snapshot else { continue }
      let previous = previousStatuses[device.id] ?? [:]

      unreadAgents = AgentUnread.applying(
        previous: previous,
        agents: snapshot.agents,
        unread: unreadAgents,
        deviceID: device.id
      )

      if !previous.isEmpty {
        notifyTransitions(
          device: device,
          snapshot: snapshot,
          previous: previous,
          selectedPane: model.selectedPaneRef
        )
      }

      previousStatuses[device.id] = Dictionary(
        uniqueKeysWithValues: snapshot.agents.map { ($0.paneID, $0.status) }
      )
    }
  }

  func selectionChanged(from oldValue: FleetPaneRef?, to newValue: FleetPaneRef?) {
    guard let oldValue, oldValue != newValue else { return }
    unreadAgents.remove(
      AgentUnreadKey(deviceID: oldValue.deviceID, paneID: oldValue.paneID)
    )
  }

  func isUnread(_ ref: FleetPaneRef) -> Bool {
    unreadAgents.contains(
      AgentUnreadKey(deviceID: ref.deviceID, paneID: ref.paneID)
    )
  }

  func attention(in entry: MobileSpaceEntry) -> SpaceAttention {
    let agents = entry.device.snapshot?.agents.filter {
      $0.workspaceID == entry.workspace.workspaceID
    } ?? []
    return SpaceAttention.rollup(agents.map {
      (
        status: $0.status,
        unreadDone: isUnread(
          FleetPaneRef(deviceID: entry.device.id, paneID: $0.paneID)
        )
      )
    })
  }

  func scopeAttention(model: MobileAppModel) -> SpaceAttention {
    let devices: [MobileDeviceEntry]
    if let selectedDeviceID = model.selectedDeviceID {
      devices = model.deviceEntries.filter { $0.id == selectedDeviceID }
    } else {
      devices = model.deviceEntries
    }
    return SpaceAttention.rollup(devices.flatMap { device in
      (device.snapshot?.agents ?? []).map {
        (
          status: $0.status,
          unreadDone: isUnread(
            FleetPaneRef(deviceID: device.id, paneID: $0.paneID)
          )
        )
      }
    })
  }

  private func notifyTransitions(
    device: MobileDeviceEntry,
    snapshot: SessionSnapshot,
    previous: [String: AgentStatus],
    selectedPane: FleetPaneRef?
  ) {
    for agent in snapshot.agents {
      guard let old = previous[agent.paneID], old != agent.status else { continue }
      guard agent.status == .blocked || agent.status == .done else { continue }

      let ref = FleetPaneRef(deviceID: device.id, paneID: agent.paneID)
      // Finishing while the terminal is visible still becomes unread, matching
      // macOS, but does not need a redundant foreground banner.
      if agent.status == .done, selectedPane == ref { continue }

      let tabLabel = snapshot.tabs?
        .first { $0.tabID == agent.tabID }?.customLabel
      MobileNotificationManager.shared.post(
        agent: agent,
        title: agent.title(tabLabel: tabLabel),
        status: agent.status,
        ref: ref,
        deviceName: device.name,
        spaceName: snapshot.workspaces
          .first { $0.workspaceID == agent.workspaceID }?.label
          ?? agent.workspaceID
      )
    }
  }
}

@MainActor
extension MobileAppModel {
  func reveal(_ ref: FleetPaneRef) {
    if let selectedDeviceID, selectedDeviceID != ref.deviceID {
      self.selectedDeviceID = nil
    }
    selectedSpaceRef = nil
    selectedPaneRef = ref
  }

  func reveal(_ ref: FleetSpaceRef) {
    if let selectedDeviceID, selectedDeviceID != ref.deviceID {
      self.selectedDeviceID = nil
    }
    selectSpace(ref)
  }
}
