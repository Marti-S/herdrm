import SwiftUI

struct MobileFleetSidebarView: View {
  @Bindable var model: MobileAppModel
  let actions: MobileActionCoordinator
  let attention: MobileAttentionController
  @Binding var showSearch: Bool

  var body: some View {
    List(selection: $model.selectedPaneRef) {
      if !model.hasConfiguredSources {
        emptyState
      } else {
        connectionSection
        devicesSection
        spacesSection
        agentsSection
        terminalsSection
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("herdrm")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        MobileDeviceSwitcherMenu(model: model)
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          showSearch = true
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel(String(localized: "Search"))

        MobileAddMenu(model: model, actions: actions)
      }
    }
    .refreshable { await model.refreshAll() }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(String(localized: "No Macs"), systemImage: "desktopcomputer")
    } description: {
      Text(String(localized: "Pair with HerdrM on your Mac, or add a direct SSH connection."))
    } actions: {
      Button(String(localized: "Add Connection")) {
        model.showAddConnection = true
      }
      .buttonStyle(.borderedProminent)
    }
    .listRowSeparator(.hidden)
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

  @ViewBuilder
  private var devicesSection: some View {
    if model.deviceEntries.count > 1 {
      Section(String(localized: "Devices")) {
        Button {
          model.selectDevice(nil)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
              .foregroundStyle(model.selectedDeviceID == nil ? Color.accentColor : .secondary)
            Text(String(localized: "All Devices"))
              .fontWeight(model.selectedDeviceID == nil ? .semibold : .regular)
            Spacer()
            Text("\(model.deviceEntries.count)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain)

        ForEach(model.deviceEntries) { device in
          Button {
            model.selectDevice(device.id)
          } label: {
            HStack(spacing: 10) {
              MobileConnectionDot(state: device.state)
              VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                  .fontWeight(model.selectedDeviceID == device.id ? .semibold : .regular)
                  .lineLimit(1)
                Text(device.subtitle)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var spacesSection: some View {
    Section(String(localized: "Spaces")) {
      Button {
        model.selectSpace(nil)
      } label: {
        MobileSpaceRow(
          label: String(localized: "All Spaces"),
          deviceName: nil,
          count: model.spaces.count,
          selected: model.selectedSpaceRef == nil,
          attention: attention.scopeAttention(model: model)
        )
      }
      .buttonStyle(.plain)

      ForEach(model.spaces) { entry in
        Button {
          model.selectSpace(entry.ref)
        } label: {
          MobileSpaceRow(
            label: entry.workspace.label,
            deviceName: model.showsDeviceBadges ? entry.device.name : nil,
            count: nil,
            selected: model.selectedSpaceRef == entry.ref,
            attention: attention.attention(in: entry)
          )
        }
        .buttonStyle(.plain)
        .contextMenu {
          Button(String(localized: "Rename")) {
            actions.sheet = .renameSpace(entry)
          }
          Button(String(localized: "Close Space"), role: .destructive) {
            actions.closeRequest = MobileCloseRequest(
              title: String(localized: "Close \(entry.workspace.label)?"),
              message: String(localized: "This closes the Space and every Agent and terminal inside it."),
              action: .space(entry.ref)
            )
          }
        }
      }
    }
  }

  private var agentsSection: some View {
    Section(String(localized: "Agents")) {
      if model.agents.isEmpty {
        Text(String(localized: "No Agents"))
          .foregroundStyle(.secondary)
          .font(.callout)
      }
      ForEach(model.agents) { entry in
        let title = entry.agent.title(tabLabel: model.tabLabel(for: entry))
        NavigationLink(value: entry.ref) {
          MobileAgentRow(
            agent: entry.agent,
            title: title,
            spaceName: model.spaceName(
              deviceID: entry.device.id,
              workspaceID: entry.agent.workspaceID
            ),
            deviceName: model.showsDeviceBadges ? entry.device.name : nil,
            unreadDone: attention.isUnread(entry.ref)
          )
        }
        .contextMenu {
          Button(String(localized: "Rename")) {
            actions.sheet = .renameAgent(entry)
          }
          Button(String(localized: "Close Agent"), role: .destructive) {
            actions.closeRequest = MobileCloseRequest(
              title: String(localized: "Close \(title)?"),
              message: String(localized: "The Agent process and its terminal pane will be closed."),
              action: .pane(entry.ref)
            )
          }
        }
      }
    }
  }

  @ViewBuilder
  private var terminalsSection: some View {
    if !model.terminalPanes.isEmpty {
      Section(String(localized: "Terminals")) {
        ForEach(model.terminalPanes) { entry in
          let title = model.terminalLabel(for: entry)
          NavigationLink(value: entry.ref) {
            MobileTerminalRow(
              title: title,
              spaceName: model.spaceName(
                deviceID: entry.device.id,
                workspaceID: entry.pane.workspaceID
              ),
              deviceName: model.showsDeviceBadges ? entry.device.name : nil
            )
          }
          .contextMenu {
            if entry.pane.tabID != nil {
              Button(String(localized: "Rename")) {
                actions.sheet = .renameTerminal(entry)
              }
            }
            Button(String(localized: "Close Terminal"), role: .destructive) {
              actions.closeRequest = MobileCloseRequest(
                title: String(localized: "Close \(title)?"),
                message: String(localized: "The persistent terminal pane will be closed."),
                action: .pane(entry.ref)
              )
            }
          }
        }
      }
    }
  }
}
