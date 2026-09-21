import AppKit
import HerdrKit
import SwiftUI

struct NewTerminalSheet: View {
    @ObservedObject var model: FleetStore
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID = Device.local.id
    @State private var workspaceID = ""

    private var chosenDevice: Device {
        model.device(deviceID) ?? .local
    }

    private var spaces: [WorkspaceInfo] {
        model.session(deviceID).workspaces
    }

    private var isStandalone: Bool { workspaceID.isEmpty }

    private var spaceLabel: String {
        spaces.first { $0.workspaceID == workspaceID }?.label ?? String(localized: "a Herdr space")
    }

    private var subtitle: String {
        if isStandalone {
            return chosenDevice.isLocal
                ? String(localized: "Start a login shell on this Mac")
                : String(localized: "Connect to \(chosenDevice.name) over SSH")
        }
        return String(localized: "Creates a persistent shell in \(spaceLabel) on \(chosenDevice.name)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "terminal",
                title: String(localized: "New Terminal"),
                subtitle: subtitle
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
                        workspaceID = spaces.first?.workspaceID ?? ""
                    }

                    Spacer().frame(height: 8)
                }

                SheetSectionLabel("SPACE")
                // A herdr space gives a persistent, reattachable server-owned
                // shell; Standalone is an app-owned process (plain login shell
                // or ssh) that needs no herdr on the device at all.
                Picker("", selection: $workspaceID) {
                    ForEach(spaces) { workspace in
                        Text(workspace.label).tag(workspace.workspaceID)
                    }
                    Text("Standalone (not in a space)").tag("")
                }
                .labelsHidden()
                .fixedSize()
                if isStandalone {
                    Text("Runs in this app only; closing herdrm ends the shell.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Terminal") {
                    if isStandalone {
                        model.newShellSession(on: chosenDevice)
                    } else {
                        model.startNewTerminal(device: chosenDevice, workspaceID: workspaceID)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .onAppear {
            deviceID = model.selectedSpace?.deviceID
                ?? model.selectedAttachedEntry?.device.id
                ?? model.deviceFilter
                ?? model.devices.first?.id
                ?? Device.local.id
            let preferredSpace = model.selectedSpace?.deviceID == deviceID
                ? model.selectedSpace?.workspaceID
                : model.selectedAttachedEntry.flatMap {
                    $0.device.id == deviceID ? $0.workspaceID : nil
                }
            workspaceID = preferredSpace.flatMap { preferred in
                spaces.contains { $0.workspaceID == preferred } ? preferred : nil
            } ?? spaces.first?.workspaceID ?? ""
        }
    }
}
