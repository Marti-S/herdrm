import HerdrKit
import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var collapsed: Bool
    @State private var deviceButtonHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // 28pt titlebar strip: traffic lights on the left, collapse toggle on the right
            HStack {
                Spacer()
                TitlebarIconButton(systemName: "sidebar.left", help: "Hide Sidebar (⌘B)") {
                    collapsed = true
                }
            }
            .padding(.horizontal, 10)
            .frame(height: TitlebarMetrics.height)

            Spacer().frame(height: 8)

            VStack(spacing: 1) {
                actionRow(icon: "square.and.pencil", label: "New Agent") {
                    model.showNewAgent = true
                }
                actionRow(icon: "magnifyingglass", label: "Search") {
                    model.showSearch = true
                }
            }
            .padding(.horizontal, 10)

            Spacer().frame(height: 10)

            ScrollView {
                VStack(spacing: 1) {
                    HStack(spacing: 5) {
                        Text("Spaces")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textGhost)
                        Spacer()
                        Button {
                            model.createNewSpace()
                        } label: {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textGhost)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("New Space")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    spaceRow(id: nil, name: "All Spaces", count: model.agents.count)
                    ForEach(model.workspaces) { workspace in
                        spaceRow(id: workspace.workspaceID, name: workspace.label,
                                 count: model.agentCount(inSpace: workspace.workspaceID))
                            .contextMenu {
                                Button("Close Space \"\(workspace.label)\"…", role: .destructive) {
                                    model.requestCloseSpace(workspace)
                                }
                            }
                    }

                    Spacer().frame(height: 10)

                    groupHeader("Agents")
                    if model.visibleAgents.isEmpty {
                        Text(emptyAgentsHint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textGhost)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    ForEach(model.visibleAgents) { agent in
                        agentRow(agent)
                            .contextMenu {
                                Button("Close Agent…", role: .destructive) {
                                    model.requestClosePane(agent.paneID, name: agent.title)
                                }
                            }
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)
            footer
        }
        .frame(width: 260)
        .background(VisualEffectView(material: .sidebar).ignoresSafeArea())
    }

    private var emptyAgentsHint: String {
        switch model.connection {
        case .connecting: return "Connecting…"
        case .failed(let reason): return reason
        default: return "No agents"
        }
    }

    // MARK: - Rows

    private func actionRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
    }

    private func groupHeader(_ title: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textGhost)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func spaceRow(id: String?, name: String, count: Int) -> some View {
        let selected = model.selectedSpaceID == id
        return Button {
            model.selectSpace(id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: id == nil ? "square.grid.2x2" : "folder")
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Theme.textSecondary : Theme.textTertiary)
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textGhost)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(selected: selected))
    }

    private func agentRow(_ agent: AgentInfo) -> some View {
        let selected = model.selectedPaneID == agent.paneID
        return Button {
            model.selectedPaneID = agent.paneID
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.title)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    statusGlyph(agent.status)
                }
                HStack(spacing: 5) {
                    AgentKindBadge(kind: agent.agent)
                    Text("·")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textGhost)
                    Image(systemName: "folder")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(spaceName(agent.workspaceID))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    trailingDetail(agent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(height: 51)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(selected: selected))
    }

    @ViewBuilder
    private func statusGlyph(_ status: AgentStatus) -> some View {
        switch status {
        case .working:
            SpinnerView(color: Theme.working)
                .frame(width: 12, height: 12)
        case .blocked:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.warning)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Theme.success)
        case .idle, .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private func trailingDetail(_ agent: AgentInfo) -> some View {
        if agent.status == .blocked {
            Text("needs input")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.warning)
        }
    }

    private func spaceName(_ workspaceID: String) -> String {
        model.workspaces.first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }

    // MARK: - Footer (device switcher)

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                model.showDevicePanel.toggle()
            } label: {
                HStack(spacing: 6) {
                    DeviceIcon(osID: model.activeDevice.osID, isLocal: model.activeDevice.isLocal, size: 10)
                        .foregroundStyle(Theme.textSecondary)
                    Text(model.activeDevice.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 6, height: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(deviceButtonHovered || model.showDevicePanel
                          ? AnyShapeStyle(Theme.itemWashSelected)
                          : AnyShapeStyle(Theme.itemWash))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.hairline, lineWidth: deviceButtonHovered ? 1 : 0)
            )
            .scaleEffect(deviceButtonHovered ? 1.04 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: deviceButtonHovered)
            .onHover { deviceButtonHovered = $0 }

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private var connectionDotColor: Color {
        switch model.connection {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textGhost
        }
    }
}

/// Small icon button that sits in the 28pt titlebar strip.
struct TitlebarIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered ? AnyShapeStyle(Theme.itemWash) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// Custom device switcher popover, matching the DeviceSwitcher design artboard:
/// two-line device rows with OS icon, status dot, and a check on the current device.
struct DevicePopover: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("DEVICES")
                .font(.system(size: 10.5, weight: .medium))
                .kerning(0.3)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 9)
                .frame(height: 24, alignment: .leading)

            ForEach(model.devices) { device in
                DevicePopoverRow(
                    device: device,
                    isActive: device.id == model.activeDeviceID,
                    isConnected: device.id == model.activeDeviceID && isConnectedState
                ) {
                    isPresented = false
                    model.switchDevice(device)
                }
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)

            actionRow(icon: "plus", label: "Add Device…") {
                isPresented = false
                model.showAddDevice = true
            }
            if !model.activeDevice.isLocal {
                actionRow(icon: "pencil", label: "Edit \(model.activeDevice.name)…") {
                    isPresented = false
                    model.deviceToEdit = model.activeDevice
                }
                actionRow(icon: "minus.circle", label: "Remove \(model.activeDevice.name)") {
                    isPresented = false
                    model.removeDevice(model.activeDevice)
                }
            }
        }
        .padding(5)
        .frame(width: 252)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private var isConnectedState: Bool {
        if case .connected = model.connection { return true }
        return false
    }

    private func actionRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
    }
}

struct DevicePopoverRow: View {
    let device: Device
    let isActive: Bool
    let isConnected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                DeviceIcon(osID: device.osID, isLocal: device.isLocal, size: 13)
                    .foregroundStyle(isActive ? Theme.text : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                        Circle()
                            .fill(isActive
                                  ? (isConnected ? Theme.success : Theme.warning)
                                  : Theme.textGhost)
                            .frame(width: 6, height: 6)
                    }
                    Text(device.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered || isActive ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .onHover { hovered = $0 }
    }
}

struct SidebarRowButtonStyle: ButtonStyle {
    var selected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected || configuration.isPressed ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
    }
}

struct SpinnerView: View {
    let color: Color
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
