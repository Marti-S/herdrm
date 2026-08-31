import HerdrKit
import SwiftUI
import UIKit

/// iPhone: a navigation stack (fleet → terminal). iPad: a split view whose
/// sidebar follows the Mac app's Spaces, Agents, Terminals, and device filter.
struct MobileRootView: View {
  @Bindable var model: MobileAppModel

  var body: some View {
    NavigationSplitView {
      SidebarListView(model: model)
    } detail: {
      if let entry = model.selectedAgent,
        let transport = model.transport(for: entry.ref.deviceID)
      {
        MobileTerminalScreen(
          transport: transport,
          target: .agent(paneID: entry.agent.paneID),
          paneID: entry.agent.paneID,
          title: entry.agent.title(tabLabel: model.tabLabel(for: entry))
        )
        .id(entry.ref)
      } else if let entry = model.selectedTerminalPane,
        let terminalID = entry.pane.terminalID,
        let transport = model.transport(for: entry.ref.deviceID)
      {
        MobileTerminalScreen(
          transport: transport,
          target: .terminal(terminalID: terminalID),
          paneID: entry.pane.paneID,
          title: model.terminalLabel(for: entry)
        )
        .id(entry.ref)
      } else {
        ContentUnavailableView(
          String(localized: "No Terminal Selected"),
          systemImage: "terminal",
          description: Text(
            String(localized: "Pick an agent or terminal from the fleet.")
          )
        )
      }
    }
    .sheet(isPresented: $model.showAddConnection) {
      AddConnectionSheet(model: model)
    }
    .task { model.activate() }
  }
}

private struct SidebarListView: View {
  @Bindable var model: MobileAppModel

  var body: some View {
    List(selection: $model.selectedPaneRef) {
      if !model.hasConfiguredSources {
        ContentUnavailableView {
          Label(String(localized: "No Macs"), systemImage: "desktopcomputer")
        } description: {
          Text(
            String(localized: "Pair with HerdrM on your Mac, or add a direct SSH connection.")
          )
        } actions: {
          Button(String(localized: "Add Connection")) {
            model.showAddConnection = true
          }
          .buttonStyle(.borderedProminent)
        }
        .listRowSeparator(.hidden)
      } else {
        connectionSection
        spacesSection
        agentsSection
        terminalsSection
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("herdrm")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        DeviceSwitcherMenu(model: model)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          model.showAddConnection = true
        } label: {
          Image(systemName: "plus")
        }
        .accessibilityLabel(String(localized: "Add Connection"))
      }
    }
    .refreshable { await model.refreshAll() }
  }

  @ViewBuilder
  private var connectionSection: some View {
    switch model.selectedConnectionState {
    case .idle, .connecting:
      HStack(spacing: 8) {
        ProgressView()
        Text(String(localized: "Connecting…"))
          .foregroundStyle(.secondary)
      }
      .listRowSeparator(.hidden)

    case .failed(let reason):
      VStack(alignment: .leading, spacing: 8) {
        Text(reason)
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button(String(localized: "Reconnect")) { model.activate() }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
      .listRowSeparator(.hidden)

    case .connected:
      EmptyView()
    }
  }

  private var spacesSection: some View {
    Section(String(localized: "Spaces")) {
      Button {
        model.selectSpace(nil)
      } label: {
        SpaceRow(
          label: String(localized: "All Spaces"),
          systemImage: "square.grid.2x2",
          count: model.spaces.count,
          selected: model.selectedSpaceRef == nil,
          deviceName: nil
        )
      }
      .buttonStyle(.plain)

      ForEach(model.spaces) { entry in
        Button {
          model.selectSpace(entry.ref)
        } label: {
          SpaceRow(
            label: entry.workspace.label,
            systemImage: "folder",
            count: nil,
            selected: model.selectedSpaceRef == entry.ref,
            deviceName: model.showsDeviceBadges ? entry.device.name : nil
          )
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var agentsSection: some View {
    Section(String(localized: "Agents")) {
      if model.agents.isEmpty {
        Text(String(localized: "No agents"))
          .foregroundStyle(.secondary)
          .font(.callout)
      }
      ForEach(model.agents) { entry in
        NavigationLink(value: entry.ref) {
          AgentRow(
            agent: entry.agent,
            title: entry.agent.title(tabLabel: model.tabLabel(for: entry)),
            spaceName: model.spaceName(
              deviceID: entry.ref.deviceID,
              workspaceID: entry.agent.workspaceID
            ),
            deviceName: model.showsDeviceBadges ? entry.device.name : nil
          )
        }
      }
    }
  }

  @ViewBuilder
  private var terminalsSection: some View {
    if !model.terminalPanes.isEmpty {
      Section(String(localized: "Terminals")) {
        ForEach(model.terminalPanes) { entry in
          NavigationLink(value: entry.ref) {
            HStack(spacing: 10) {
              Image(systemName: "terminal")
                .foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(model.terminalLabel(for: entry))
                  .lineLimit(1)
                HStack(spacing: 4) {
                  Text(
                    model.spaceName(
                      deviceID: entry.ref.deviceID,
                      workspaceID: entry.pane.workspaceID
                    ))
                  if model.showsDeviceBadges {
                    Text("·")
                    Text(entry.device.name)
                  }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
              }
            }
          }
        }
      }
    }
  }
}

private struct SpaceRow: View {
  let label: String
  let systemImage: String
  let count: Int?
  let selected: Bool
  let deviceName: String?

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(selected ? Color.accentColor : .secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(label)
          .fontWeight(selected ? .semibold : .regular)
        if let deviceName {
          Text(deviceName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer()
      if let count {
        Text("\(count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
  }
}

private struct AgentRow: View {
  let agent: AgentInfo
  let title: String
  let spaceName: String
  let deviceName: String?

  var body: some View {
    HStack(spacing: 10) {
      StatusGlyph(status: agent.status)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .lineLimit(1)
        HStack(spacing: 4) {
          Text(agent.agent)
          Text("·")
          Text(spaceName)
          if let deviceName {
            Text("·")
            Text(deviceName)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer()
      if agent.status == .blocked {
        Text(String(localized: "needs input"))
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.orange.opacity(0.18), in: Capsule())
          .foregroundStyle(.orange)
      }
    }
  }
}

private struct StatusGlyph: View {
  let status: AgentStatus

  var body: some View {
    switch status {
    case .working:
      ProgressView().controlSize(.small)
    case .blocked:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
    case .done:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .idle, .unknown:
      Image(systemName: "circle")
        .foregroundStyle(.secondary)
    }
  }
}

private struct DeviceSwitcherMenu: View {
  @Bindable var model: MobileAppModel

  var body: some View {
    if model.hasConfiguredSources {
      Menu {
        Button {
          model.selectDevice(nil)
        } label: {
          if model.selectedDeviceID == nil {
            Label(String(localized: "All Devices"), systemImage: "checkmark")
          } else {
            Text(String(localized: "All Devices"))
          }
        }

        ForEach(model.deviceEntries) { candidate in
          Button {
            model.selectDevice(candidate.id)
          } label: {
            if candidate.id == model.selectedDeviceID {
              Label(candidate.name, systemImage: "checkmark")
            } else {
              Text(candidate.name)
            }
          }
        }

        Divider()
        Button(String(localized: "Add Connection…")) {
          model.showAddConnection = true
        }
        if model.bridge != nil {
          Button(String(localized: "Remove Mac Bridge"), role: .destructive) {
            model.removeBridge()
          }
        }
        if let selected = model.selectedDevice {
          switch selected.source {
          case .bridge:
            EmptyView()
          case .direct:
            Button(
              String(localized: "Remove \(selected.name)"),
              role: .destructive
            ) {
              model.removeDirectDevice(selected.id)
            }
          }
        }
      } label: {
        HStack(spacing: 6) {
          ConnectionDot(state: model.selectedConnectionState)
          Text(
            model.selectedDevice?.name
              ?? String(localized: "All Devices")
          )
          .font(.callout.weight(.medium))
          .lineLimit(1)
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

private struct ConnectionDot: View {
  let state: MobileConnectionState

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
  }

  private var color: Color {
    switch state {
    case .connected: return .green
    case .connecting: return .yellow
    case .failed: return .red
    case .idle: return .gray
    }
  }
}
