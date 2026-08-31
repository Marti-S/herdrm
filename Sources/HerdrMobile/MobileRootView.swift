import HerdrKit
import SwiftUI
import UIKit

/// iPhone uses a navigation stack; iPad presents the same fleet sidebar beside
/// the selected terminal. A paired Mac defaults to All Devices and mirrors the
/// Mac app's Spaces, Agents, and persistent Herdr terminals.
struct MobileRootView: View {
    @Bindable var model: MobileAppModel

    var body: some View {
        NavigationSplitView {
            SidebarListView(model: model)
        } detail: {
            if let entry = model.selectedAgentEntry,
               let transport = model.transport(for: entry.device.id) {
                MobileTerminalScreen(
                    transport: transport,
                    target: .agent(paneID: entry.agent.paneID),
                    paneID: entry.agent.paneID,
                    title: entry.title
                )
                .id(entry.ref)
            } else if let entry = model.selectedTerminalEntry,
                      let terminalID = entry.pane.terminalID,
                      let transport = model.transport(for: entry.device.id) {
                MobileTerminalScreen(
                    transport: transport,
                    target: .terminal(terminalID: terminalID),
                    paneID: entry.pane.paneID,
                    title: entry.title
                )
                .id(entry.ref)
            } else {
                ContentUnavailableView(
                    String(localized: "No Terminal Selected"),
                    systemImage: "terminal",
                    description: Text(String(localized: "Pick an agent or terminal from the fleet."))
                )
            }
        }
        .sheet(isPresented: $model.showAddBridge) {
            AddBridgeSheet(model: model)
        }
        .sheet(isPresented: $model.showAddDevice) {
            AddDeviceSheet(model: model)
        }
        .task { model.activate() }
    }
}

private struct SidebarListView: View {
    @Bindable var model: MobileAppModel

    var body: some View {
        List(selection: $model.selectedPaneRef) {
            if !model.hasSources {
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
                SourceSwitcherMenu(model: model)
            }
            ToolbarItem(placement: .topBarTrailing) {
                AddSourceMenu(model: model)
            }
        }
        .refreshable { await model.refreshActive() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No Macs"), systemImage: "desktopcomputer")
        } description: {
            Text(String(localized: "Pair the Mac bridge to see every HerdrM device, Space, Agent, and terminal."))
        } actions: {
            Button(String(localized: "Pair Mac")) { model.showAddBridge = true }
                .buttonStyle(.borderedProminent)
            Button(String(localized: "Add Direct SSH")) { model.showAddDevice = true }
                .buttonStyle(.bordered)
        }
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var connectionSection: some View {
        switch model.selectedSourceConnectionState {
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
                Button(String(localized: "Reconnect")) { model.connectSelectedSource() }
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
        if model.selectedSourceIsBridge, !model.fleetDevices.isEmpty {
            Section(String(localized: "Devices")) {
                Button {
                    model.selectFleetDevice(nil)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(model.selectedFleetDeviceID == nil ? Color.accentColor : .secondary)
                        Text(String(localized: "All Devices"))
                            .fontWeight(model.selectedFleetDeviceID == nil ? .semibold : .regular)
                        Spacer()
                        Text("\(model.fleetDevices.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                ForEach(model.fleetDevices) { device in
                    Button {
                        model.selectFleetDevice(device.id)
                    } label: {
                        HStack(spacing: 10) {
                            ConnectionDot(state: model.connectionState(for: device.id))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.device.name)
                                    .fontWeight(model.selectedFleetDeviceID == device.id ? .semibold : .regular)
                                    .lineLimit(1)
                                Text(device.device.subtitle)
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
                SpaceRow(
                    label: String(localized: "All Spaces"),
                    deviceName: nil,
                    count: model.spaces.count,
                    selected: model.selectedSpaceRef == nil
                )
            }
            .buttonStyle(.plain)

            ForEach(model.spaces) { entry in
                Button {
                    model.selectSpace(entry.ref)
                } label: {
                    SpaceRow(
                        label: entry.workspace.label,
                        deviceName: model.showsDeviceBadges ? entry.device.name : nil,
                        count: nil,
                        selected: model.selectedSpaceRef == entry.ref
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
                        title: entry.title,
                        spaceName: model.spaceName(
                            deviceID: entry.device.id,
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
        if !model.terminals.isEmpty {
            Section(String(localized: "Terminals")) {
                ForEach(model.terminals) { entry in
                    NavigationLink(value: entry.ref) {
                        HStack(spacing: 10) {
                            Image(systemName: "terminal")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(model.spaceName(
                                        deviceID: entry.device.id,
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
    let deviceName: String?
    let count: Int?
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
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
                Text(title).lineLimit(1)
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
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .idle, .unknown:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

private struct SourceSwitcherMenu: View {
    @Bindable var model: MobileAppModel

    var body: some View {
        if model.hasSources {
            Menu {
                if !model.bridgeHosts.isEmpty {
                    Section(String(localized: "Mac Bridges")) {
                        ForEach(model.bridgeHosts) { bridge in
                            Button {
                                model.selectBridge(bridge.id)
                            } label: {
                                if model.selectedSourceID == .bridge(bridge.id) {
                                    Label(bridge.name, systemImage: "checkmark")
                                } else {
                                    Text(bridge.name)
                                }
                            }
                        }
                    }
                }
                if !model.directDevices.isEmpty {
                    Section(String(localized: "Direct SSH")) {
                        ForEach(model.directDevices) { device in
                            Button {
                                model.selectDirectDevice(device.id)
                            } label: {
                                if model.selectedSourceID == .direct(device.id) {
                                    Label(device.name, systemImage: "checkmark")
                                } else {
                                    Text(device.name)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button(String(localized: "Pair Mac…")) { model.showAddBridge = true }
                Button(String(localized: "Add Direct SSH…")) { model.showAddDevice = true }
                Button(
                    String(localized: "Remove \(model.selectedSourceName)"),
                    role: .destructive
                ) {
                    model.removeSelectedSource()
                }
            } label: {
                HStack(spacing: 6) {
                    ConnectionDot(state: model.selectedSourceConnectionState)
                    Text(model.selectedSourceName)
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

private struct AddSourceMenu: View {
    @Bindable var model: MobileAppModel

    var body: some View {
        Menu {
            Button(String(localized: "Pair Mac Bridge")) { model.showAddBridge = true }
            Button(String(localized: "Add Direct SSH")) { model.showAddDevice = true }
        } label: {
            Image(systemName: "plus")
        }
    }
}

private struct ConnectionDot: View {
    let state: MobileConnectionState

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
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

struct AddBridgeSheet: View {
    @Bindable var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = String(FleetBridgeProtocol.defaultPort)
    @State private var token = ""
    @State private var serverID: UUID?
    @State private var pairingNote: String?
    @State private var parseError: String?

    private var canAdd: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && UInt16(port) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Pairing")) {
                    Button(String(localized: "Paste Pairing JSON"), action: pastePairing)
                    if let pairingNote {
                        Text(pairingNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let parseError {
                        Text(parseError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section(String(localized: "Mac Bridge")) {
                    TextField(String(localized: "Name"), text: $name)
                    TextField(String(localized: "Tailscale name or IP"), text: $host)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField(String(localized: "Port"), text: $port)
                        .keyboardType(.numberPad)
                    SecureField(String(localized: "Pairing token"), text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Text(String(localized: "Use the Mac's Tailscale IP or MagicDNS name. The token stays in this iPhone's Keychain; SSH credentials remain on the Mac."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "Pair Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Pair")) {
                        model.addBridge(
                            name: name,
                            host: host,
                            port: UInt16(port) ?? FleetBridgeProtocol.defaultPort,
                            token: token,
                            serverID: serverID
                        )
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }

    private func pastePairing() {
        parseError = nil
        pairingNote = nil
        guard let text = UIPasteboard.general.string,
              let data = text.data(using: .utf8)
        else {
            parseError = String(localized: "The clipboard does not contain pairing JSON.")
            return
        }
        do {
            let payload = try JSONDecoder().decode(MobileBridgePairingPayload.self, from: data)
            guard payload.protocolVersion == FleetBridgeProtocol.version else {
                throw MobileBridgeClientError.protocolMismatch(payload.protocolVersion)
            }
            name = payload.serverName
            host = payload.hostHint
            port = String(payload.port)
            token = payload.token
            serverID = payload.serverID
            pairingNote = payload.loopbackOnly
                ? String(localized: "This Mac currently listens on loopback. Configure a Tailscale TCP forward or enable all-interface bridge listening, then replace the host with its Tailscale name.")
                : String(localized: "Pairing data loaded. Confirm the Mac's Tailscale address before connecting.")
        } catch {
            parseError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct AddDeviceSheet: View {
    @Bindable var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: MobileDevice.AuthMethod = .deviceKey
    @State private var password = ""
    @State private var copiedKey = false

    private var canAdd: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (authMethod == .deviceKey || !password.isEmpty)
            && UInt16(port) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Device")) {
                    TextField(String(localized: "Name (optional)"), text: $name)
                    TextField(String(localized: "Host or IP"), text: $host)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField(String(localized: "Port"), text: $port)
                        .keyboardType(.numberPad)
                }
                Section(String(localized: "SSH Login")) {
                    TextField(String(localized: "Username"), text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker(String(localized: "Authentication"), selection: $authMethod) {
                        Text(String(localized: "Device Key")).tag(MobileDevice.AuthMethod.deviceKey)
                        Text(String(localized: "Password")).tag(MobileDevice.AuthMethod.password)
                    }
                    if authMethod == .password {
                        SecureField(String(localized: "Password"), text: $password)
                            .textContentType(.password)
                    }
                }
                if authMethod == .deviceKey {
                    Section(String(localized: "This Phone's Key")) {
                        Text(model.deviceKeyAuthorizedLine)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Button(copiedKey
                            ? String(localized: "Copied")
                            : String(localized: "Copy authorized_keys Line")
                        ) {
                            UIPasteboard.general.string = model.deviceKeyAuthorizedLine
                            copiedKey = true
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Add Direct SSH"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Add")) {
                        model.addDirectDevice(
                            name: name,
                            host: host,
                            port: UInt16(port) ?? 22,
                            username: username,
                            authMethod: authMethod,
                            password: password
                        )
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }
}
