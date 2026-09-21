import HerdrKit
import SwiftUI

struct MobileNewAgentSheet: View {
    let model: MobileAppModel
    let actions: MobileActionCoordinator
    @Environment(\.dismiss) private var dismiss
    @AppStorage("agent.bypassDefault") private var bypass = true
    @State private var deviceID: UUID?
    @State private var workspaceID: String?
    @State private var kinds: [String] = []
    @State private var kind = ""
    @State private var loadingKinds = false
    @State private var loadError: String?

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
    private var bypassFlags: [String]? {
        MobileAgentLaunchOptions.bypassFlags(for: kind)
    }
    private var canCreate: Bool {
        deviceID != nil
            && workspaceID != nil
            && kinds.contains(kind)
            && !loadingKinds
            && !actions.isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                deviceSection
                agentSection
                workspaceSection
                if let bypassFlags {
                    Section(String(localized: "Options")) {
                        Toggle(String(localized: "Bypass permissions"), isOn: $bypass)
                        Text(bypassFlags.joined(separator: " "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(String(localized: "New Agent"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Start"), action: submit)
                        .disabled(!canCreate)
                }
            }
            .onAppear(perform: normalizeSelection)
            .onChange(of: deviceID) { _, _ in chooseWorkspace() }
            .task(id: deviceID) { await loadKinds() }
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
    private var agentSection: some View {
        Section(String(localized: "Agent")) {
            if loadingKinds {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(String(localized: "Loading Agent catalog…"))
                }
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary)
                Button(String(localized: "Retry")) {
                    Task { await loadKinds() }
                }
            } else if kinds.isEmpty {
                Text(String(localized: "This device advertises no supported Agents."))
                    .foregroundStyle(.secondary)
            } else {
                Picker(String(localized: "Agent"), selection: $kind) {
                    ForEach(kinds, id: \.self) { kind in
                        Text(kind).tag(kind)
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

    private func loadKinds() async {
        guard let deviceID else {
            kinds = []
            kind = ""
            return
        }
        loadingKinds = true
        loadError = nil
        defer { loadingKinds = false }
        do {
            let loaded = try await model.availableAgentKinds(deviceID: deviceID)
            guard !Task.isCancelled else { return }
            kinds = loaded
            if !loaded.contains(kind) { kind = loaded.first ?? "" }
        } catch {
            guard !Task.isCancelled else { return }
            kinds = []
            kind = ""
            loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func submit() {
        guard let deviceID, let workspaceID else { return }
        let selectedKind = kind
        let useBypass = bypass && bypassFlags != nil
        dismiss()
        actions.run {
            try await model.createAgent(
                deviceID: deviceID,
                workspaceID: workspaceID,
                kind: selectedKind,
                bypassPermissions: useBypass
            )
        }
    }
}
