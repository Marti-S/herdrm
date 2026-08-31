import Foundation
import HerdrKit
import SwiftUI

/// Fleet-wide search over Agents, persistent terminals, and Spaces. Search is
/// intentionally independent of the current device/Space filter.
struct MobileSearchSheet: View {
  @Bindable var model: MobileAppModel
  let attention: MobileAttentionController

  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  private enum Result: Identifiable {
    case agent(MobileAgentEntry)
    case terminal(MobileTerminalEntry)
    case space(MobileSpaceEntry)

    var id: String {
      switch self {
      case .agent(let entry):
        return "agent-\(entry.ref.deviceID.uuidString)-\(entry.ref.paneID)"
      case .terminal(let entry):
        return "terminal-\(entry.ref.deviceID.uuidString)-\(entry.ref.paneID)"
      case .space(let entry):
        return "space-\(entry.ref.deviceID.uuidString)-\(entry.ref.workspaceID)"
      }
    }
  }

  private var results: [Result] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    let agents = allAgents.filter { entry in
      q.isEmpty
        || agentTitle(entry).lowercased().contains(q)
        || entry.agent.agent.lowercased().contains(q)
        || (entry.agent.name?.lowercased().contains(q) ?? false)
        || (entry.agent.terminalTitleStripped ?? entry.agent.terminalTitle)?
          .lowercased().contains(q) == true
        || entry.device.name.lowercased().contains(q)
        || model.spaceName(
          deviceID: entry.device.id,
          workspaceID: entry.agent.workspaceID
        ).lowercased().contains(q)
    }
    .sorted { lhs, rhs in
      let left = searchRank(lhs)
      let right = searchRank(rhs)
      if left != right { return left < right }
      return (lhs.agent.revision ?? 0) > (rhs.agent.revision ?? 0)
    }

    let terminals = allTerminals.filter { entry in
      q.isEmpty
        || model.terminalLabel(for: entry).lowercased().contains(q)
        || (entry.pane.cwd?.lowercased().contains(q) ?? false)
        || entry.device.name.lowercased().contains(q)
        || model.spaceName(
          deviceID: entry.device.id,
          workspaceID: entry.pane.workspaceID
        ).lowercased().contains(q)
    }

    let spaces = allSpaces.filter { entry in
      q.isEmpty
        || entry.workspace.label.lowercased().contains(q)
        || entry.device.name.lowercased().contains(q)
    }

    return agents.map(Result.agent)
      + terminals.map(Result.terminal)
      + spaces.map(Result.space)
  }

  var body: some View {
    NavigationStack {
      Group {
        if results.isEmpty {
          ContentUnavailableView.search(text: query)
        } else {
          List(results) { result in
            Button {
              choose(result)
            } label: {
              row(result)
            }
            .buttonStyle(.plain)
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle(String(localized: "Search"))
      .navigationBarTitleDisplayMode(.inline)
      .searchable(
        text: $query,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: String(localized: "Agents, terminals, Spaces, devices")
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(String(localized: "Done")) { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  @ViewBuilder
  private func row(_ result: Result) -> some View {
    switch result {
    case .agent(let entry):
      MobileAgentRow(
        agent: entry.agent,
        title: agentTitle(entry),
        spaceName: model.spaceName(
          deviceID: entry.device.id,
          workspaceID: entry.agent.workspaceID
        ),
        deviceName: showsDeviceNames ? entry.device.name : nil,
        unreadDone: attention.isUnread(entry.ref)
      )

    case .terminal(let entry):
      MobileTerminalRow(
        title: model.terminalLabel(for: entry),
        spaceName: model.spaceName(
          deviceID: entry.device.id,
          workspaceID: entry.pane.workspaceID
        ),
        deviceName: showsDeviceNames ? entry.device.name : nil
      )

    case .space(let entry):
      MobileSpaceRow(
        label: entry.workspace.label,
        deviceName: showsDeviceNames ? entry.device.name : nil,
        count: entry.device.snapshot?.agents.filter {
          $0.workspaceID == entry.workspace.workspaceID
        }.count,
        selected: false,
        attention: attention.attention(in: entry)
      )
    }
  }

  private var allAgents: [MobileAgentEntry] {
    model.deviceEntries.flatMap { device in
      (device.snapshot?.agents ?? []).map {
        MobileAgentEntry(
          ref: FleetPaneRef(deviceID: device.id, paneID: $0.paneID),
          agent: $0,
          device: device
        )
      }
    }
  }

  private var allTerminals: [MobileTerminalEntry] {
    model.deviceEntries.flatMap { device in
      (device.snapshot?.ordinaryTerminalPanes ?? []).map {
        MobileTerminalEntry(
          ref: FleetPaneRef(deviceID: device.id, paneID: $0.paneID),
          pane: $0,
          device: device
        )
      }
    }
  }

  private var allSpaces: [MobileSpaceEntry] {
    model.deviceEntries.flatMap { device in
      (device.snapshot?.workspaces ?? []).map {
        MobileSpaceEntry(
          ref: FleetSpaceRef(deviceID: device.id, workspaceID: $0.workspaceID),
          workspace: $0,
          device: device
        )
      }
    }
  }

  private var showsDeviceNames: Bool {
    model.deviceEntries.count > 1
  }

  private func agentTitle(_ entry: MobileAgentEntry) -> String {
    entry.agent.title(tabLabel: model.tabLabel(for: entry))
  }

  private func searchRank(_ entry: MobileAgentEntry) -> Int {
    switch entry.agent.status {
    case .blocked: return 0
    case .done where attention.isUnread(entry.ref): return 1
    case .working: return 2
    case .done: return 3
    case .idle: return 4
    case .unknown: return 5
    }
  }

  private func choose(_ result: Result) {
    switch result {
    case .agent(let entry):
      model.reveal(entry.ref)
    case .terminal(let entry):
      model.reveal(entry.ref)
    case .space(let entry):
      model.reveal(entry.ref)
    }
    dismiss()
  }
}
