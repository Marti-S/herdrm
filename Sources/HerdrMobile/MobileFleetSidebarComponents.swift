import HerdrKit
import SwiftUI

struct MobileSpaceRow: View {
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

struct MobileAgentRow: View {
    let agent: AgentInfo
    let title: String
    let spaceName: String
    let deviceName: String?

    var body: some View {
        HStack(spacing: 10) {
            MobileStatusGlyph(status: agent.status)
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

struct MobileTerminalRow: View {
    let title: String
    let spaceName: String
    let deviceName: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                HStack(spacing: 4) {
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
        }
    }
}

struct MobileStatusGlyph: View {
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

struct MobileDeviceSwitcherMenu: View {
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
                if let selected = model.selectedDevice,
                   case .direct = selected.source {
                    Button(
                        String(localized: "Remove \(selected.name)"),
                        role: .destructive
                    ) {
                        model.removeDirectDevice(selected.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    MobileConnectionDot(state: model.selectedConnectionState)
                    Text(model.selectedDevice?.name ?? String(localized: "All Devices"))
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

struct MobileAddMenu: View {
    @Bindable var model: MobileAppModel
    let actions: MobileActionCoordinator

    var body: some View {
        let actionsDisabled = model.actionDevices.isEmpty || actions.isWorking
        Menu {
            Section(String(localized: "Create")) {
                Button(String(localized: "New Agent"), systemImage: "sparkles") {
                    actions.sheet = .newAgent(
                        deviceID: model.preferredActionDeviceID,
                        workspaceID: model.selectedSpaceRef?.workspaceID
                    )
                }
                .disabled(actionsDisabled)
                Button(String(localized: "New Terminal"), systemImage: "terminal") {
                    actions.sheet = .newTerminal(
                        deviceID: model.preferredActionDeviceID,
                        workspaceID: model.selectedSpaceRef?.workspaceID
                    )
                }
                .disabled(actionsDisabled)
                Button(String(localized: "New Space"), systemImage: "folder.badge.plus") {
                    actions.sheet = .newSpace(deviceID: model.preferredActionDeviceID)
                }
                .disabled(actionsDisabled)
            }

            Section(String(localized: "Connections")) {
                Button(String(localized: "Add Connection"), systemImage: "network") {
                    model.showAddConnection = true
                }
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}

struct MobileConnectionDot: View {
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
