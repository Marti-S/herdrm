import HerdrKit
import SwiftUI

struct MobileNewTerminalSheet: View {
    let model: MobileAppModel
    let actions: MobileActionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID: UUID?
    @State private var workspaceID: String?
    @State private var label = ""

    init(
        model: MobileAppModel,
        actions: MobileActionCoordinator,
        initialDeviceID: UUID?,
        initialWorkspaceID: String?
    ) {
        self.model = model
        self.actions = actions
        _deviceID = State(initialValue: initialDeviceID)
        _workspaceID = State(initialValue: initialWorkspaceID)
    }

    private var devices: [MobileDeviceEntry] { model.actionDevices }
    private var workspaces: [WorkspaceInfo] {
        deviceID.map(model.actionWorkspaces(deviceID:)) ?? []
    }
    private var canCreate: Bool {
        deviceID != nil && workspaceID != nil && !actions.isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                deviceSection
                workspaceSection
                Section(String(localized: "Terminal")) {
                    TextField(String(localized: "Name (optional)"), text: $label)
                    Text(String(localized: "Creates a persistent Herdr terminal that remains available on the Mac and iOS."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "New Terminal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Create"), action: submit)
                        .disabled(!canCreate)
                }
            }
            .onAppear(perform: normalizeSelection)
            .onChange(of: deviceID) { _, _ in chooseWorkspace() }
            .onChange(of: devices.map(\.id)) { _, _ in normalizeSelection() }
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        if devices.isEmpty {
            Section {
                ContentUnavailableView(
                    String(localized: "No Connected Devices"),
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark"
                )
            }
        } else if devices.count > 1 {
            Section(String(localized: "Device")) {
                Picker(String(localized: "Device"), selection: $deviceID) {
                    ForEach(devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var workspaceSection: some View {
        Section(String(localized: "Space")) {
            if workspaces.isEmpty {
                Text(String(localized: "This device has no Spaces. Create one first."))
                    .foregroundStyle(.secondary)
            } else {
                Picker(String(localized: "Space"), selection: $workspaceID) {
                    ForEach(workspaces) { workspace in
                        Text(workspace.label).tag(Optional(workspace.workspaceID))
                    }
                }
            }
        }
    }

    private func normalizeSelection() {
        if deviceID.flatMap({ id in devices.contains { $0.id == id } ? id : nil }) == nil {
            deviceID = model.preferredActionDeviceID ?? devices.first?.id
        }
        chooseWorkspace()
    }

    private func chooseWorkspace() {
        if workspaceID.flatMap({ id in workspaces.contains { $0.workspaceID == id } ? id : nil }) == nil {
            workspaceID = workspaces.first?.workspaceID
        }
    }

    private func submit() {
        guard let deviceID, let workspaceID else { return }
        dismiss()
        actions.run {
            try await model.createTerminal(
                deviceID: deviceID,
                workspaceID: workspaceID,
                label: label
            )
        }
    }
}
