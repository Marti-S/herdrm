import SwiftUI

/// iPhone uses a navigation stack; iPad presents the same fleet sidebar beside
/// the selected terminal. A paired Mac defaults to All Devices and mirrors the
/// Mac app's Spaces, Agents, and persistent Herdr terminals.
struct MobileRootView: View {
  @Bindable var model: MobileAppModel
  @State private var actions = MobileActionCoordinator()
  @State private var attention = MobileAttentionController()
  @State private var showSearch = false

  var body: some View {
    NavigationSplitView {
      MobileFleetSidebarView(
        model: model,
        actions: actions,
        attention: attention,
        showSearch: $showSearch
      )
    } detail: {
      detail
    }
    .sheet(isPresented: $model.showAddConnection) {
      AddConnectionSheet(model: model)
    }
    .sheet(isPresented: $showSearch) {
      MobileSearchSheet(model: model, attention: attention)
    }
    .sheet(item: $actions.sheet) { route in
      MobileActionSheetHost(route: route, model: model, actions: actions)
    }
    .alert(
      String(localized: "Something went wrong"),
      isPresented: Binding(
        get: { actions.errorMessage != nil },
        set: { if !$0 { actions.errorMessage = nil } }
      )
    ) {
      Button(String(localized: "OK"), role: .cancel) {}
    } message: {
      Text(actions.errorMessage ?? "")
    }
    .alert(
      actions.closeRequest?.title ?? String(localized: "Close"),
      isPresented: Binding(
        get: { actions.closeRequest != nil },
        set: { if !$0 { actions.closeRequest = nil } }
      )
    ) {
      Button(String(localized: "Close"), role: .destructive) {
        actions.performClose(using: model)
      }
      Button(String(localized: "Cancel"), role: .cancel) {
        actions.closeRequest = nil
      }
    } message: {
      Text(actions.closeRequest?.message ?? "")
    }
    .overlay(alignment: .topTrailing) {
      if actions.isWorking {
        ProgressView()
          .padding(12)
          .background(.regularMaterial, in: Circle())
          .padding()
      }
    }
    .onChange(of: model.revision) { _, _ in
      attention.process(model: model)
    }
    .onChange(of: model.selectedPaneRef) { oldValue, newValue in
      attention.selectionChanged(from: oldValue, to: newValue)
    }
    .task {
      MobileNotificationManager.shared.setup(model: model)
      attention.process(model: model)
      model.activate()
    }
  }

  @ViewBuilder
  private var detail: some View {
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
        description: Text(String(localized: "Pick an Agent or terminal from the fleet."))
      )
    }
  }
}
