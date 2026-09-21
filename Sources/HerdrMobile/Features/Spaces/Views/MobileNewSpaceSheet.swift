import HerdrKit
import SwiftUI

struct MobileNewSpaceSheet: View {
    let model: MobileAppModel
    let actions: MobileActionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID: UUID?
    @State private var label = ""
    @State private var cwd = "~/"

    init(
        model: MobileAppModel,
        actions: MobileActionCoordinator,
        initialDeviceID: UUID?
    ) {
        self.model = model
        self.actions = actions
        _deviceID = State(initialValue: initialDeviceID)
    }

    private var devices: [MobileDeviceEntry] { model.actionDevices }
    private var canCreate: Bool { deviceID != nil && !actions.isWorking }

    var body: some View {
        NavigationStack {
            Form {
                deviceSection
                Section(String(localized: "Space")) {
                    TextField(String(localized: "Name (optional)"), text: $label)
                    TextField(String(localized: "Directory"), text: $cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(String(localized: "The directory is resolved on the selected device. Leave it empty to use Herdr's default."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "New Space"))
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
            .onAppear(perform: chooseDeviceIfNeeded)
            .onChange(of: devices.map(\.id)) { _, _ in chooseDeviceIfNeeded() }
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        if devices.isEmpty {
            Section {
                ContentUnavailableView(
                    String(localized: "No Connected Devices"),
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                    description: Text(String(localized: "Reconnect a device before creating a Space."))
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

    private func chooseDeviceIfNeeded() {
        if deviceID.flatMap({ id in devices.contains { $0.id == id } ? id : nil }) == nil {
            deviceID = model.preferredActionDeviceID ?? devices.first?.id
        }
    }

    private func submit() {
        guard let deviceID else { return }
        dismiss()
        actions.run {
            try await model.createSpace(
                deviceID: deviceID,
                label: label,
                cwd: cwd
            )
        }
    }
}
