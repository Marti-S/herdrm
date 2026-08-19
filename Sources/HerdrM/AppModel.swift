import Foundation
import HerdrKit
import SwiftUI

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected(version: String)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [Device]
    @Published var activeDeviceID: UUID
    @Published var connection: ConnectionState = .idle
    @Published var agents: [AgentInfo] = []
    @Published var workspaces: [WorkspaceInfo] = []
    @Published var panes: [PaneInfo] = []
    @Published var selectedSpaceID: String?
    @Published var selectedPaneID: String?
    @Published var showAddDevice = false
    @Published var showNewAgent = false
    @Published var showNewSpace = false
    @Published var showSearch = false
    /// In-window device panel (NSPopover crashes in ViewBridge on macOS 26+ betas).
    @Published var showDevicePanel = false
    @Published var deviceToEdit: Device?
    /// Transient action failures (start agent, create space…): shown as an alert,
    /// never by tearing down the connection state.
    @Published var actionError: String?

    /// A pending destructive close, confirmed via alert before running.
    struct CloseRequest {
        let title: String
        let message: String
        let perform: () -> Void
    }
    @Published var closeRequest: CloseRequest?

    private let store = DeviceStore()
    private var services: [UUID: HerdrService] = [:]
    private var eventTask: Task<Void, Never>?
    private var refreshDebounce: Task<Void, Never>?

    init() {
        let loaded = DeviceStore().load()
        devices = loaded
        activeDeviceID = loaded[0].id
    }

    var activeDevice: Device {
        devices.first { $0.id == activeDeviceID } ?? .local
    }

    var activeService: HerdrService {
        if let service = services[activeDeviceID] { return service }
        let service = HerdrService(device: activeDevice)
        services[activeDeviceID] = service
        return service
    }

    var selectedAgent: AgentInfo? {
        agents.first { $0.paneID == selectedPaneID }
    }

    /// Agent kinds supported by the connected herdr server (for the New Agent picker).
    @Published var agentKinds: [String] = []
    /// The subset of agentKinds actually installed on the active device.
    @Published var installedAgentKinds: [String] = []

    /// Agents filtered by selected space, sorted by status bucket then recency proxy.
    var visibleAgents: [AgentInfo] {
        let filtered = selectedSpaceID == nil
            ? agents
            : agents.filter { $0.workspaceID == selectedSpaceID }
        return filtered.sorted {
            if $0.status.sortBucket != $1.status.sortBucket {
                return $0.status.sortBucket < $1.status.sortBucket
            }
            return ($0.revision ?? 0) > ($1.revision ?? 0)
        }
    }

    func agentCount(inSpace workspaceID: String) -> Int {
        agents.filter { $0.workspaceID == workspaceID }.count
    }

    func selectSpace(_ id: String?) {
        selectedSpaceID = id
        if let agent = selectedAgent, id == nil || agent.workspaceID == id { return }
        selectedPaneID = visibleAgents.first?.paneID
    }

    // MARK: - Lifecycle

    func start() {
        connect(to: activeDevice)
        // Sniff OS for every known device up front so the switcher shows brand icons.
        for device in devices {
            probeOSIfNeeded(device)
        }
    }

    func switchDevice(_ device: Device) {
        guard device.id != activeDeviceID else { return }
        eventTask?.cancel()
        activeDeviceID = device.id
        selectedSpaceID = nil
        selectedPaneID = nil
        agents = []
        workspaces = []
        panes = []
        agentKinds = []
        installedAgentKinds = []
        connect(to: device)
    }

    func addDevice(name: String, sshTarget: String) {
        let device = Device(name: name, kind: .ssh(target: sshTarget))
        devices.append(device)
        store.save(devices)
        switchDevice(device)
    }

    // MARK: - Closing

    func requestCloseSpace(_ workspace: WorkspaceInfo) {
        closeRequest = CloseRequest(
            title: "Close space \"\(workspace.label)\"?",
            message: "All terminals and agents in this space will be closed."
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.activeService.closeWorkspace(workspaceID: workspace.workspaceID)
                    if self.selectedSpaceID == workspace.workspaceID {
                        self.selectedSpaceID = nil
                    }
                    await self.refresh()
                } catch {
                    self.actionError = error.localizedDescription
                }
            }
        }
    }

    func requestClosePane(_ paneID: String, name: String) {
        closeRequest = CloseRequest(
            title: "Close \"\(name)\"?",
            message: "The pane and whatever is running inside it will be terminated."
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.activeService.closePane(paneID: paneID)
                    if self.selectedPaneID == paneID {
                        self.selectedPaneID = nil
                    }
                    await self.refresh()
                } catch {
                    self.actionError = error.localizedDescription
                }
            }
        }
    }

    /// Renames a device and/or updates its SSH target (e.g. after an IP change).
    func updateDevice(_ id: UUID, name: String, sshTarget: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }), !devices[index].isLocal else { return }
        let targetChanged = devices[index].sshTarget != sshTarget
        devices[index].name = name
        if targetChanged {
            devices[index].kind = .ssh(target: sshTarget)
            devices[index].osID = nil
            services[id] = nil
            if activeDeviceID == id {
                eventTask?.cancel()
                agents = []
                workspaces = []
                selectedPaneID = nil
                connect(to: devices[index])
            }
            probeOSIfNeeded(devices[index])
        }
        store.save(devices)
    }

    func removeDevice(_ device: Device) {
        guard !device.isLocal else { return }
        devices.removeAll { $0.id == device.id }
        services[device.id] = nil
        store.save(devices)
        if activeDeviceID == device.id {
            switchDevice(.local)
        }
    }

    private func connect(to device: Device) {
        connection = .connecting
        let service = activeService
        Task {
            do {
                let pong = try await service.connect()
                guard device.id == self.activeDeviceID else { return }
                self.connection = .connected(version: pong.version)
                self.probeOSIfNeeded(device)
                await self.refresh()
                self.agentKinds = (try? await service.agentKinds()) ?? []
                self.installedAgentKinds = (try? await service.installedAgentKinds(from: self.agentKinds)) ?? []
                self.startEventLoop(service: service, deviceID: device.id)
            } catch {
                guard device.id == self.activeDeviceID else { return }
                self.connection = .failed(error.localizedDescription)
            }
        }
    }

    func refresh() async {
        do {
            let snapshot = try await activeService.snapshot()
            agents = snapshot.agents
            workspaces = snapshot.workspaces
            panes = snapshot.panes ?? []
            if let selected = selectedPaneID, !agents.contains(where: { $0.paneID == selected }) {
                selectedPaneID = nil
            }
            if selectedPaneID == nil {
                selectedPaneID = visibleAgents.first?.paneID
            }
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    private func startEventLoop(service: HerdrService, deviceID: UUID) {
        eventTask?.cancel()
        eventTask = Task {
            while !Task.isCancelled && deviceID == self.activeDeviceID {
                do {
                    let stream = try await service.events()
                    for try await _ in stream {
                        self.scheduleRefresh()
                    }
                } catch {
                    // fall through to reconnect
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func scheduleRefresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    /// Sniffs the device OS once (for the OS brand icon) and persists it.
    private func probeOSIfNeeded(_ device: Device) {
        guard device.osID == nil, let target = device.sshTarget else { return }
        Task {
            guard let os = try? await SSHTunnel.probeOS(target: target) else { return }
            if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                self.devices[index].osID = os
                self.store.save(self.devices)
            }
        }
    }

    // MARK: - Actions

    /// Creates a workspace rooted at the given directory ("~" expands to the device's
    /// home, local or remote), then goes straight into the New Agent sheet for it.
    func createNewSpace(directory: String, label: String?) {
        Task {
            do {
                var path = directory.trimmingCharacters(in: .whitespaces)
                if path.isEmpty { path = "~" }
                if path == "~" || path.hasPrefix("~/") {
                    let home = try await activeService.homeDirectory()
                    path = path == "~" ? home : "\(home)/\(path.dropFirst(2))"
                }
                let trimmedLabel = label?.trimmingCharacters(in: .whitespaces)
                let created = try await activeService.createWorkspace(
                    label: (trimmedLabel?.isEmpty ?? true) ? nil : trimmedLabel,
                    cwd: path
                )
                await refresh()
                selectedSpaceID = created.workspaceID
                showNewAgent = true
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// New Agent: a fresh tab in the space plus agent.start. Agent names are
    /// session-global in herdr, so collisions retry with a unique suffix.
    /// `bypass` appends the kind's skip-permissions flag when one is known.
    func startNewAgent(kind: String, workspaceID: String?, bypass: Bool) {
        let args = bypass ? (HerdrService.bypassFlags(for: kind) ?? []) : []
        Task {
            var createdPane: String?
            do {
                let pane = try await activeService.createTab(
                    workspaceID: workspaceID,
                    cwd: nil,
                    label: kind
                )
                createdPane = pane
                do {
                    try await activeService.startAgent(name: kind, kind: kind, paneID: pane, args: args)
                } catch HerdrError.rpc(let code, _) where code == "agent_name_taken" {
                    let suffix = String(UUID().uuidString.prefix(4)).lowercased()
                    try await activeService.startAgent(name: "\(kind)-\(suffix)", kind: kind, paneID: pane, args: args)
                }
                await refresh()
                selectedPaneID = pane
            } catch {
                if let createdPane {
                    try? await activeService.closePane(paneID: createdPane)
                }
                actionError = error.localizedDescription
            }
        }
    }
}
