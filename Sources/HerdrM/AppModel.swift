import Foundation
import HerdrKit
import SwiftTerm
import SwiftUI

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected(version: String)
    case failed(String)
}

/// Global pane identity: pane ids like "w1:p1" collide across devices.
struct PaneRef: Hashable {
    let deviceID: UUID
    let paneID: String
}

struct SpaceRef: Hashable {
    let deviceID: UUID
    let workspaceID: String
}

/// Live state for one device's herdr session.
struct DeviceSessionState {
    var connection: ConnectionState = .idle
    var agents: [AgentInfo] = []
    var workspaces: [WorkspaceInfo] = []
    var panes: [PaneInfo] = []
    var agentKinds: [String] = []
    var installedAgentKinds: [String] = []
    var attachmentCapabilities = AgentAttachmentCapabilityRegistry()
}

struct SSHAuthenticationRequest: Identifiable {
    let deviceID: UUID
    let target: String

    var id: UUID { deviceID }
}

/// vertical = panes side by side with a vertical divider (iTerm2's convention).
enum SplitAxis { case vertical, horizontal }

/// Identifies one of the two panes in the ⌘D split. Used for focus tracking and
/// keyboard-driven resize; standalone `ShellSession`s are not part of this.
enum SplitSide { case agent, shell }

/// A standalone local shell shown as its own sidebar entry — not a herdr pane
/// (herdr refuses to attach agent-less panes) and not the ⌘D split.
struct ShellSession: Identifiable, Equatable {
    let id: UUID
    var title: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [Device]
    /// All devices stay connected in parallel; this only filters the sidebar.
    @Published var deviceFilter: UUID?
    @Published var sessions: [UUID: DeviceSessionState] = [:]
    @Published var selectedSpace: SpaceRef?
    @Published var selectedPane: PaneRef?

    @Published var showAddDevice = false
    @Published var showNewAgent = false
    @Published var showNewSpace = false
    @Published var showSearch = false
    @Published var shellSplitAxis: SplitAxis?
    /// The pane that currently holds the keyboard within the ⌘D split. Reset to
    /// the agent side whenever the split closes so reopening it is predictable.
    @Published var activeSplitSide: SplitSide = .agent
    /// Persisted divider ratio for the ⌘D split, shared with the resize commands.
    /// Deliberately not `@AppStorage`: that publishes only from inside a View, so the
    /// menu commands would write UserDefaults without ever redrawing the split.
    @Published var splitRatio: Double =
        UserDefaults.standard.object(forKey: AppModel.splitRatioKey) as? Double ?? 0.5
    {
        didSet { UserDefaults.standard.set(splitRatio, forKey: AppModel.splitRatioKey) }
    }
    static let splitRatioKey = "terminal.splitRatio"
    /// Live terminal views of the ⌘D split, used by menu commands to move focus.
    /// Held weakly so the views are not kept alive by the model.
    weak var splitAgentView: LocalProcessTerminalView?
    weak var splitShellView: LocalProcessTerminalView?
    /// Standalone local terminals. Their views stay alive while deselected —
    /// unlike agents, a local shell has no server side to reattach to.
    @Published var shellSessions: [ShellSession] = []
    @Published var selectedShellID: UUID?
    /// In-window device panel (NSPopover crashes in ViewBridge on macOS 26+ betas).
    @Published var showDevicePanel = false
    @Published var deviceToEdit: Device?
    @Published var sshAuthenticationRequest: SSHAuthenticationRequest?
    @Published var spaceToRename: SpaceEntry?
    /// Transient action failures: shown as an alert, never by tearing down sessions.
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
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshDebounces: [UUID: Task<Void, Never>] = [:]
    private var previousStatuses: [UUID: [String: AgentStatus]] = [:]

    init() {
        devices = DeviceStore().load()
    }

    // MARK: - Derived state

    func device(_ id: UUID) -> Device? {
        devices.first { $0.id == id }
    }

    func session(_ id: UUID) -> DeviceSessionState {
        sessions[id] ?? DeviceSessionState()
    }

    /// The herdr version the device's server reported on its last successful
    /// ping; the terminal attach uses it to pick a protocol-matching CLI binary.
    func serverVersion(deviceID: UUID) -> String? {
        if case .connected(let version) = session(deviceID).connection { return version }
        return nil
    }

    func attachmentCapabilities(
        deviceID: UUID,
        agentKind: String?
    ) -> AgentAttachmentCapabilities? {
        session(deviceID).attachmentCapabilities.capabilities(for: agentKind)
    }

    var filteredDevice: Device? {
        deviceFilter.flatMap(device)
    }

    private var devicesInScope: [Device] {
        if let filtered = filteredDevice { return [filtered] }
        return devices
    }

    /// Aggregate connection state for the current scope (footer dot, hints).
    var connection: ConnectionState {
        let states = devicesInScope.map { session($0.id).connection }
        if let failed = states.first(where: { if case .failed = $0 { return true }; return false }) {
            return failed
        }
        if states.contains(.connecting) { return .connecting }
        if !states.isEmpty, states.allSatisfy({ if case .connected = $0 { return true }; return false }) {
            return .connected(version: "")
        }
        return states.isEmpty ? .idle : .connecting
    }

    struct AgentEntry: Identifiable {
        let device: Device
        let agent: AgentInfo

        var id: String { "\(device.id.uuidString)-\(agent.paneID)" }
        var ref: PaneRef { PaneRef(deviceID: device.id, paneID: agent.paneID) }
    }

    struct SpaceEntry: Identifiable {
        let device: Device
        let workspace: WorkspaceInfo

        var id: String { "\(device.id.uuidString)-\(workspace.workspaceID)" }
        var ref: SpaceRef { SpaceRef(deviceID: device.id, workspaceID: workspace.workspaceID) }
    }

    var visibleSpaces: [SpaceEntry] {
        devicesInScope.flatMap { device in
            session(device.id).workspaces.map { SpaceEntry(device: device, workspace: $0) }
        }
    }

    /// Agents across the scope, filtered by selected space, status-bucket sorted.
    var visibleAgents: [AgentEntry] {
        var entries = devicesInScope.flatMap { device in
            session(device.id).agents.map { AgentEntry(device: device, agent: $0) }
        }
        if let space = selectedSpace {
            entries = entries.filter {
                $0.device.id == space.deviceID && $0.agent.workspaceID == space.workspaceID
            }
        }
        return entries.sorted {
            if $0.agent.status.sortBucket != $1.agent.status.sortBucket {
                return $0.agent.status.sortBucket < $1.agent.status.sortBucket
            }
            return ($0.agent.revision ?? 0) > ($1.agent.revision ?? 0)
        }
    }

    var scopeAgentCount: Int {
        devicesInScope.reduce(0) { $0 + session($1.id).agents.count }
    }

    var selectedEntry: AgentEntry? {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return nil }
        guard let agent = session(selected.deviceID).agents.first(where: { $0.paneID == selected.paneID })
        else { return nil }
        return AgentEntry(device: device, agent: agent)
    }

    func agentCount(in entry: SpaceEntry) -> Int {
        session(entry.device.id).agents.filter { $0.workspaceID == entry.workspace.workspaceID }.count
    }

    func spaceName(deviceID: UUID, workspaceID: String) -> String {
        session(deviceID).workspaces.first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }

    /// Show device badges only when more than one device is configured.
    var showsDeviceBadges: Bool {
        devices.count > 1
    }

    // MARK: - Selection

    func selectSpace(_ ref: SpaceRef?) {
        selectedSpace = ref
        selectedShellID = nil
        if let entry = selectedEntry {
            if ref == nil { return }
            if entry.device.id == ref!.deviceID && entry.agent.workspaceID == ref!.workspaceID { return }
        }
        selectedPane = visibleAgents.first?.ref
    }

    func setDeviceFilter(_ id: UUID?) {
        deviceFilter = id
        if let id, let space = selectedSpace, space.deviceID != id {
            selectedSpace = nil
        }
        if let id, let entry = selectedEntry, entry.device.id != id {
            selectedPane = visibleAgents.first?.ref
        }
    }

    /// Set by `reveal` when a jump lands while the ⌘D split is open, and consumed once the
    /// main window is key again. Only an actual jump sets it: dismissing the search with
    /// Escape never calls `reveal`, and the sidebar assigns `selectedPane` directly.
    @Published var pendingSplitAgentFocus = false

    /// Jump target used by the search sheet and by notification clicks.
    func reveal(_ ref: PaneRef) {
        if let filter = deviceFilter, filter != ref.deviceID {
            deviceFilter = nil
        }
        selectedSpace = nil
        selectedPane = ref
        selectedShellID = nil
        // Only the search sheet needs the deferred request: its dismissal restores the
        // parent window's previous responder after the view tree has asked for focus.
        // `showSearch` is still true here — SearchView calls this before dismissing.
        //
        // Notification clicks deliberately do NOT arm it. With the app already frontmost
        // there may be no key-window transition at all, so nothing would consume the flag
        // and a later unrelated activation would cash it in, pulling the keyboard out of
        // the shell. Those clicks get focus from the recreated attach and from the
        // entry-change request instead.
        if shellSplitAxis != nil, showSearch { pendingSplitAgentFocus = true }
    }

    // MARK: - Shell terminals

    var selectedShell: ShellSession? {
        selectedShellID.flatMap { id in shellSessions.first { $0.id == id } }
    }

    /// Every click opens another terminal, like New Agent opens another agent.
    func newShellSession() {
        let session = ShellSession(id: UUID(), title: "Terminal \(shellSessions.count + 1)")
        shellSessions.append(session)
        selectShell(session.id)
    }

    func selectShell(_ id: UUID) {
        selectedShellID = id
        ShellViewRegistry.focus(id)
    }

    func closeShellSession(_ id: UUID) {
        shellSessions.removeAll { $0.id == id }
        if selectedShellID == id {
            selectedShellID = shellSessions.last?.id
            if let remaining = selectedShellID { ShellViewRegistry.focus(remaining) }
        }
    }

    // MARK: - Lifecycle

    func start() {
        NotificationManager.shared.setup(model: self)
        for device in devices {
            startSession(device)
            probeOSIfNeeded(device)
        }
    }

    func service(for device: Device) -> HerdrService {
        if let service = services[device.id] { return service }
        let service = HerdrService(device: device)
        services[device.id] = service
        return service
    }

    /// Runs one device's session: connect, snapshot, event stream, and reconnect
    /// with exponential backoff (1s → 30s) whenever the connection drops.
    private func startSession(_ device: Device) {
        sessionTasks[device.id]?.cancel()
        if sessions[device.id] == nil { sessions[device.id] = DeviceSessionState() }
        let service = service(for: device)
        sessionTasks[device.id] = Task { [weak self] in
            var backoff: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                self.sessions[device.id]?.connection = .connecting
                do {
                    let pong = try await service.connect()
                    self.sessions[device.id]?.connection = .connected(version: pong.version)
                    backoff = 1
                    // retried on every successful connect until it sticks (a fresh
                    // device's first probes can fail before its host key is known)
                    if let current = self.device(device.id) {
                        self.probeOSIfNeeded(current)
                    }
                    await self.refresh(device.id)
                    if let manifests = try? await service.agentManifests() {
                        let kinds = manifests.map(\.agent)
                        self.sessions[device.id]?.agentKinds = kinds
                        self.sessions[device.id]?.attachmentCapabilities =
                            AgentAttachmentCapabilityRegistry(manifests: manifests)
                        self.sessions[device.id]?.installedAgentKinds =
                            (try? await service.installedAgentKinds(from: kinds)) ?? []
                    }
                    let stream = try await service.events()
                    for try await _ in stream {
                        self.scheduleRefresh(device.id)
                    }
                } catch {
                    self.sessions[device.id]?.connection = .failed(error.localizedDescription)
                    if let target = device.sshTarget, Self.isSSHAuthenticationFailure(error) {
                        self.sshAuthenticationRequest = SSHAuthenticationRequest(
                            deviceID: device.id,
                            target: target
                        )
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    /// Tears down every live tunnel. Awaited from the app's terminate hook — `stopSession`
    /// fires its disconnect in a detached `Task`, which never runs when the process is exiting.
    func shutdownAllSessions() async {
        let live = services
        services.removeAll()
        sessionTasks.values.forEach { $0.cancel() }
        sessionTasks.removeAll()
        for service in live.values {
            await service.disconnect()
        }
    }

    private func stopSession(_ id: UUID) {
        sessionTasks[id]?.cancel()
        sessionTasks[id] = nil
        refreshDebounces[id]?.cancel()
        refreshDebounces[id] = nil
        previousStatuses[id] = nil
        let service = services[id]
        services[id] = nil
        sessions[id] = nil
        Task { await service?.disconnect() }
    }

    func addDevice(name: String, sshTarget: String) {
        let device = Device(name: name, kind: .ssh(target: sshTarget))
        devices.append(device)
        store.save(devices)
        startSession(device)
        probeOSIfNeeded(device)
        setDeviceFilter(device.id)
    }

    func saveSSHPassword(_ password: String, for request: SSHAuthenticationRequest) {
        guard !password.isEmpty,
              let device = device(request.deviceID),
              device.sshTarget == request.target
        else { return }
        do {
            try SSHCredentialStore.setPassword(password, for: device.id)
            sshAuthenticationRequest = nil
            stopSession(device.id)
            startSession(device)
            probeOSIfNeeded(device)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Leaves the device disconnected but recoverable; the reconnect loop stopped at the prompt.
    func cancelSSHAuthentication(for request: SSHAuthenticationRequest) {
        sshAuthenticationRequest = nil
        sessions[request.deviceID]?.connection =
            .failed("Authentication cancelled — choose Reconnect to try again")
    }

    var hasReconnectableDevice: Bool {
        devicesInScope.contains { isFailed($0.id) }
    }

    func reconnectFailedDevices() {
        for device in devicesInScope where isFailed(device.id) {
            stopSession(device.id)
            startSession(device)
            probeOSIfNeeded(device)
        }
    }

    private func isFailed(_ deviceID: UUID) -> Bool {
        if case .failed = session(deviceID).connection { return true }
        return false
    }

    /// Renames a device and/or updates its SSH target (e.g. after an IP change).
    func updateDevice(_ id: UUID, name: String, sshTarget: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }), !devices[index].isLocal else { return }
        let targetChanged = devices[index].sshTarget != sshTarget
        devices[index].name = name
        if targetChanged {
            removeSSHPassword(for: id)
            devices[index].kind = .ssh(target: sshTarget)
            devices[index].osID = nil
            stopSession(id)
            startSession(devices[index])
            probeOSIfNeeded(devices[index])
        }
        store.save(devices)
    }

    func removeDevice(_ device: Device) {
        guard !device.isLocal else { return }
        removeSSHPassword(for: device.id)
        if sshAuthenticationRequest?.deviceID == device.id { sshAuthenticationRequest = nil }
        stopSession(device.id)
        devices.removeAll { $0.id == device.id }
        store.save(devices)
        if deviceFilter == device.id { deviceFilter = nil }
        if selectedSpace?.deviceID == device.id { selectedSpace = nil }
        if selectedPane?.deviceID == device.id { selectedPane = visibleAgents.first?.ref }
    }

    // MARK: - Refresh

    func refresh(_ deviceID: UUID) async {
        guard let device = device(deviceID), let service = services[deviceID] else { return }
        do {
            let snapshot = try await service.snapshot()
            notifyTransitions(
                device: device,
                from: previousStatuses[deviceID] ?? [:],
                to: snapshot.agents,
                workspaces: snapshot.workspaces
            )
            previousStatuses[deviceID] = Dictionary(
                uniqueKeysWithValues: snapshot.agents.map { ($0.paneID, $0.status) }
            )
            sessions[deviceID]?.agents = snapshot.agents
            sessions[deviceID]?.workspaces = snapshot.workspaces
            sessions[deviceID]?.panes = snapshot.panes ?? []
            if let selected = selectedPane, selected.deviceID == deviceID,
               !snapshot.agents.contains(where: { $0.paneID == selected.paneID }) {
                selectedPane = nil
            }
            if let space = selectedSpace, space.deviceID == deviceID,
               !snapshot.workspaces.contains(where: { $0.workspaceID == space.workspaceID }) {
                selectedSpace = nil
            }
            if selectedPane == nil {
                selectedPane = visibleAgents.first?.ref
            }
        } catch {
            sessions[deviceID]?.connection = .failed(error.localizedDescription)
        }
    }

    private func scheduleRefresh(_ deviceID: UUID) {
        refreshDebounces[deviceID]?.cancel()
        refreshDebounces[deviceID] = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self.refresh(deviceID)
        }
    }

    /// Notifies when an agent newly becomes blocked (needs input) or done (finished
    /// while unwatched). Initial snapshots don't notify — only real transitions do.
    private func notifyTransitions(
        device: Device,
        from previous: [String: AgentStatus],
        to agents: [AgentInfo],
        workspaces: [WorkspaceInfo]
    ) {
        guard !previous.isEmpty else { return }
        for agent in agents {
            guard let old = previous[agent.paneID], old != agent.status else { continue }
            guard agent.status == .blocked || agent.status == .done else { continue }
            NotificationManager.shared.post(
                agent: agent,
                status: agent.status,
                deviceID: device.id,
                deviceName: device.name,
                spaceName: workspaces.first { $0.workspaceID == agent.workspaceID }?.label ?? agent.workspaceID
            )
        }
    }

    /// Sniffs the device OS once (for the OS brand icon) and persists it.
    private func probeOSIfNeeded(_ device: Device) {
        guard device.osID == nil, let target = device.sshTarget else { return }
        Task {
            guard let os = try? await SSHTunnel.probeOS(
                target: target,
                credentialID: device.id
            ) else { return }
            if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                self.devices[index].osID = os
                self.store.save(self.devices)
            }
        }
    }

    private static func isSSHAuthenticationFailure(_ error: Error) -> Bool {
        guard let herdrError = error as? HerdrError,
              case .tunnelFailed(let reason) = herdrError
        else { return false }
        return [
            "permission denied",
            "authentication failed",
            "too many authentication failures",
            "no supported authentication methods",
        ].contains { reason.localizedCaseInsensitiveContains($0) }
    }

    private func removeSSHPassword(for deviceID: UUID) {
        do {
            try SSHCredentialStore.removePassword(for: deviceID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// An action fired while the device session is down surfaces the bare
    /// "connection failed: not connected", which points at nothing. The
    /// reconnect loop already knows why the device is unreachable — say that
    /// instead. (#21)
    func actionErrorMessage(_ error: Error, device: Device) -> String {
        guard let herdrError = error as? HerdrError,
              case .connectionFailed(let reason) = herdrError,
              reason == "not connected"
        else { return error.localizedDescription }
        switch session(device.id).connection {
        case .connecting:
            return "Still connecting to \(device.name) — try again in a moment."
        case .failed(let reason):
            return "\(device.name) is unreachable: \(reason)"
        case .idle:
            return "\(device.name) isn't connected."
        case .connected:
            return "\(device.name) just reconnected — try again."
        }
    }

    // MARK: - Closing

    func requestCloseSpace(_ entry: SpaceEntry) {
        closeRequest = CloseRequest(
            title: "Close space \"\(entry.workspace.label)\" on \(entry.device.name)?",
            message: "All terminals and agents in this space will be closed."
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.service(for: entry.device)
                        .closeWorkspace(workspaceID: entry.workspace.workspaceID)
                    if self.selectedSpace == entry.ref { self.selectedSpace = nil }
                    await self.refresh(entry.device.id)
                } catch {
                    self.actionError = self.actionErrorMessage(error, device: entry.device)
                }
            }
        }
    }

    func requestClosePane(_ ref: PaneRef, name: String) {
        guard let device = device(ref.deviceID) else { return }
        closeRequest = CloseRequest(
            title: "Close \"\(name)\"?",
            message: "The pane and whatever is running inside it will be terminated."
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.service(for: device).closePane(paneID: ref.paneID)
                    if self.selectedPane == ref { self.selectedPane = nil }
                    await self.refresh(device.id)
                } catch {
                    self.actionError = self.actionErrorMessage(error, device: device)
                }
            }
        }
    }

    // MARK: - Actions

    func renameSpace(_ entry: SpaceEntry, label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label != entry.workspace.label else { return }
        Task {
            do {
                try await service(for: entry.device).renameWorkspace(
                    workspaceID: entry.workspace.workspaceID,
                    label: label
                )
                await refresh(entry.device.id)
            } catch {
                actionError = actionErrorMessage(error, device: entry.device)
            }
        }
    }

    /// Creates a workspace rooted at the given directory ("~" expands to the device's
    /// home, local or remote), then goes straight into the New Agent sheet for it.
    func createNewSpace(device: Device, directory: String, label: String?) {
        Task {
            do {
                let service = service(for: device)
                var path = directory.trimmingCharacters(in: .whitespaces)
                // The browser leaves paths slash-terminated; herdr wants them bare.
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if path.isEmpty { path = "~" }
                path = try await service.absolutePath(path)
                let trimmedLabel = label?.trimmingCharacters(in: .whitespaces)
                let created = try await service.createWorkspace(
                    label: (trimmedLabel?.isEmpty ?? true) ? nil : trimmedLabel,
                    cwd: path
                )
                await refresh(device.id)
                selectedSpace = SpaceRef(deviceID: device.id, workspaceID: created.workspaceID)
                showNewAgent = true
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    /// New Agent: a fresh tab in the space plus agent.start. Agent names are
    /// session-global in herdr, so collisions retry with a unique suffix.
    /// `bypass` appends the kind's skip-permissions flag when one is known.
    func startNewAgent(
        device: Device,
        kind: String,
        workspaceID: String?,
        bypass: Bool
    ) {
        let args = bypass ? (HerdrService.bypassFlags(for: kind) ?? []) : []
        Task {
            let service = service(for: device)
            var createdPane: String?
            do {
                let pane = try await service.createTab(workspaceID: workspaceID, cwd: nil, label: kind)
                createdPane = pane
                do {
                    try await service.startAgent(
                        name: kind,
                        kind: kind,
                        paneID: pane,
                        args: args,
                        waitForShell: true
                    )
                } catch HerdrError.rpc(let code, _) where code == "agent_name_taken" {
                    let suffix = String(UUID().uuidString.prefix(4)).lowercased()
                    try await service.startAgent(
                        name: "\(kind)-\(suffix)",
                        kind: kind,
                        paneID: pane,
                        args: args,
                        waitForShell: true
                    )
                }
                await refresh(device.id)
                selectedPane = PaneRef(deviceID: device.id, paneID: pane)
            } catch {
                if let createdPane {
                    try? await service.closePane(paneID: createdPane)
                }
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }
}
