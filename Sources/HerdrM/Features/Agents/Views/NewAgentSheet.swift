import AppKit
import HerdrKit
import SwiftUI

struct NewAgentSheet: View {
    @ObservedObject var model: FleetStore
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID = Device.local.id
    @State private var kind = ""
    @State private var workspaceID: String = ""
    @AppStorage("agent.bypassDefault") private var bypass = true

    private var chosenDevice: Device {
        model.device(deviceID) ?? .local
    }

    private var session: DeviceSessionState {
        model.session(deviceID)
    }

    private var kinds: [String] {
        session.agentCatalog.kinds
    }

    private var bypassFlags: [String]? {
        HerdrService.bypassFlags(for: kind)
    }

    private var spaceLabel: String {
        if workspaceID.isEmpty { return String(localized: "the focused space") }
        return session.workspaces.first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "sparkles",
                title: String(localized: "New Agent"),
                subtitle: String(localized: "Starts in \(spaceLabel), attached to its live terminal")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                if model.showsDeviceBadges {
                    SheetSectionLabel("DEVICE")
                    Picker("", selection: $deviceID) {
                        ForEach(model.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: deviceID) { _, _ in
                        workspaceID = ""
                        if !kinds.contains(kind) { kind = kinds.first ?? "" }
                    }

                    Spacer().frame(height: 8)
                }

                SheetSectionLabel("AGENT")
                Group {
                    switch session.agentCatalog {
                    case .loading:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "Checking agents on \(chosenDevice.name)…"))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 8) {
                            Text(chosenDevice.isLocal
                                ? String(localized: "Couldn’t check installed agent CLIs.")
                                : String(localized: "Couldn’t load this server’s agent catalog."))
                                .foregroundStyle(Theme.textSecondary)
                            Text(message)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(2)
                            Button("Retry") { model.reloadAgentCatalog(deviceID: deviceID) }
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    case .loaded(let loadedKinds, _) where loadedKinds.isEmpty:
                        Text(chosenDevice.isLocal
                            ? String(localized: "No supported agent CLI was found on this Mac. Install one, or set a binary path in Settings → Agents.")
                            : String(localized: "This server advertises no agent manifests."))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    case .loaded(let loadedKinds, let paths):
                        ScrollView {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                                spacing: 8
                            ) {
                                ForEach(loadedKinds, id: \.self) { name in
                                    kindCell(name, path: paths[name])
                                }
                            }
                            .padding(1)
                        }
                        .frame(maxHeight: 236)
                    }
                }

                Spacer().frame(height: 8)

                SheetSectionLabel("SPACE")
                Picker("", selection: $workspaceID) {
                    Text("Focused space").tag("")
                    ForEach(session.workspaces) { workspace in
                        Text(workspace.label).tag(workspace.workspaceID)
                    }
                }
                .labelsHidden()
                .fixedSize()

                // shown only for agents with a verified bypass flag
                if let flags = bypassFlags {
                    Spacer().frame(height: 8)

                    SheetSectionLabel("OPTIONS")
                    Toggle(isOn: $bypass) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Bypass permissions")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.text)
                            Text(flags.joined(separator: " "))
                                .font(.system(size: 10.5).monospaced())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Agent") {
                    model.startNewAgent(
                        device: chosenDevice,
                        kind: kind,
                        workspaceID: workspaceID.isEmpty ? nil : workspaceID,
                        bypass: bypass && bypassFlags != nil
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!kinds.contains(kind))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .onAppear {
            deviceID = model.selectedSpace?.deviceID
                ?? model.deviceFilter
                ?? model.devices.first?.id
                ?? Device.local.id
            workspaceID = model.selectedSpace?.deviceID == deviceID
                ? (model.selectedSpace?.workspaceID ?? "")
                : ""
            if !kinds.contains(kind) { kind = kinds.first ?? "" }
        }
        .onChange(of: kinds) { _, newKinds in
            if !newKinds.contains(kind) { kind = newKinds.first ?? "" }
        }
    }

    private func kindCell(_ name: String, path: String?) -> some View {
        let selected = kind == name
        return Button {
            kind = name
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let resource = BrandIconLoader.agentIcon(for: name) {
                        BrandIcon(resource: resource, size: 20)
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 16))
                    }
                }
                .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Text(name)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
            }
            .help(path ?? "")
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? AnyShapeStyle(Theme.accentWash) : AnyShapeStyle(Theme.itemWash))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}
