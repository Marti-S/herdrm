import Combine
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

enum FleetStateChange: Sendable {
    case device(UUID)
    case topology
}

/// Agent kinds offered by the picker. Local manifests are filtered through the
/// login-shell search PATH; remote manifests stay server-owned.
enum AgentCatalogState: Equatable {
    case loading
    case loaded(kinds: [String], paths: [String: String] = [:])
    case failed(String)

    var kinds: [String] {
        guard case .loaded(let kinds, _) = self else { return [] }
        return kinds
    }

    var paths: [String: String] {
        guard case .loaded(_, let paths) = self else { return [:] }
        return paths
    }
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
    var tabs: [TabInfo] = []
    var panes: [PaneInfo] = []
    var agentCatalog: AgentCatalogState = .loading
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
/// keyboard-driven resize.
enum SplitSide { case agent, shell }

private final class WeakTerminalViewBox {
    weak var view: LocalProcessTerminalView?

    init(_ view: LocalProcessTerminalView?) {
        self.view = view
    }
}

/// Atomic keeps the Pi-compatible one-cell ∀ indicator while workflows and
/// subagents replace the accompanying "Working..." text. Herdr's Pi manifest
/// matches that literal text, so the macOS sidebar also checks the live glyph.
enum AtomicActivityDetector {
    static func isWorking(in text: String) -> Bool {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(8)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed == "∀" || trimmed.hasPrefix("∀ ")
            }
    }
}

/// A standalone local or SSH shell shown as its own sidebar entry — app-owned,
/// outside any herdr space (unlike the persistent herdr terminals under
/// TERMINALS) and not the ⌘D split.
struct ShellSession: Identifiable, Equatable {
    let id: UUID
    var title: String
    let device: Device
}

/// Per-kind CLI path overrides persisted in user defaults. Empty means automatic
/// lookup on the login-shell search PATH. Invalid paths hide that kind until
/// the user fixes or clears the field — they never silently fall back.
enum AgentBinaryOverrides {
    static let defaultsKey = "agent.binaryOverrides"

    static func load(defaults: UserDefaults = .standard) -> [String: String] {
        (defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:])
            .reduce(into: [:]) { result, entry in
                let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result[entry.key] = value }
            }
    }

    static func save(_ overrides: [String: String], defaults: UserDefaults = .standard) {
        let trimmed = overrides.reduce(into: [String: String]()) { result, entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result[entry.key] = value }
        }
        if trimmed.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(trimmed, forKey: defaultsKey)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct SpaceSplitSession: Identifiable {
        let id: UUID
        let space: SpaceRef
        var axis: SplitAxis
        var activeSide: SplitSide
        var ratio: Double
    }

    @Published var devices: [Device]
    /// All devices stay connected in parallel; this only filters the sidebar.
    @Published var deviceFilter: UUID? {
        didSet {
            // Persisted so a relaunch restores the last selection (nil = All
            // Devices, which removes the key). Every reset path — removing the
            // filtered device, a notification jump to another device — goes
            // through this property, so the stored value can never go stale.
            UserDefaults.standard.set(deviceFilter?.uuidString, forKey: Self.deviceFilterKey)
        }
    }
    private static let deviceFilterKey = "device.filter"
    @Published var sessions: [UUID: DeviceSessionState] = [:]
    @Published var selectedSpace: SpaceRef?
    @Published var selectedPane: PaneRef? {
        didSet {
            // Leaving a finished agent marks it viewed. Staying on it while
            // the turn ends must not swallow the unread flag.
            if let old = oldValue, old != selectedPane {
                unreadAgents.remove(AgentUnreadKey(deviceID: old.deviceID, paneID: old.paneID))
            }
        }
    }
    /// Finished agents the user has not opened since they flipped to `done`.
    @Published private(set) var unreadAgents: Set<AgentUnreadKey> = []

    @Published var showAddDevice = false
    @Published var showNewAgent = false
    @Published var showNewTerminal = false
    @Published var showNewSpace = false
    @Published var showSearch = false
    @Published var isFileManagerActive = false
    @Published var shellSplitAxis: SplitAxis? {
        didSet { persistCurrentSplitSession() }
    }
    /// Set by `reveal` when a jump lands while the ⌘D split is open, and consumed once the
    /// main window is key again. Only an actual jump sets it: dismissing the search with
    /// Escape never calls `reveal`, and the sidebar assigns `selectedPane` directly.
    @Published var pendingSplitAgentFocus = false
    /// The pane that currently holds the keyboard within the ⌘D split. Reset to
    /// the agent side whenever the split closes so reopening it is predictable.
    @Published var activeSplitSide: SplitSide = .agent {
        didSet { persistCurrentSplitSession() }
    }
    /// Persisted divider ratio for the ⌘D split, shared with the resize commands.
    /// Deliberately not `@AppStorage`: that publishes only from inside a View, so the
    /// menu commands would write UserDefaults without ever redrawing the split.
    @Published var splitRatio: Double =
        UserDefaults.standard.object(forKey: AppModel.splitRatioKey) as? Double ?? 0.5
    {
        didSet {
            UserDefaults.standard.set(splitRatio, forKey: AppModel.splitRatioKey)
            persistCurrentSplitSession()
        }
    }
    static let splitRatioKey = "terminal.splitRatio"
    /// One app-owned sidecar shell per Space that has explicitly opened ⌘D.
    @Published private var splitSessionsBySpace: [SpaceRef: SpaceSplitSession] = [:]
    private var splitShellViews: [SpaceRef: WeakTerminalViewBox] = [:]
    private var restoringSplitSession = false
    /// Live terminal views of the ⌘D split, used by menu commands to move focus.
    /// Held weakly so the views are not kept alive by the model.
    weak var splitAgentView: LocalProcessTerminalView?
    weak var splitShellView: LocalProcessTerminalView?
    @Published private var atomicPaneRefs: Set<PaneRef> = []
    @Published private var atomicWorkingPanes: Set<PaneRef> = []
    @Published private var branchesByPane: [PaneRef: String] = [:]
    /// Standalone terminals. Their views stay alive while deselected —
    /// unlike agents, a local shell has no server side to reattach to.
    @Published var shellSessions: [ShellSession] = []
    @Published var selectedShellID: UUID?
    /// In-window device panel (NSPopover crashes in ViewBridge on macOS 26+ betas).
    @Published var showDevicePanel = false
    @Published var deviceToEdit: Device?
    @Published var sshAuthenticationRequest: SSHAuthenticationRequest?
    @Published var spaceToRename: SpaceEntry?
    @Published var agentToRename: AgentEntry?
    /// Transient action failures: shown as an alert, never by tearing down sessions.
    @Published var actionError: String?

    /// A pending destructive close, confirmed via alert before running.
    struct CloseRequest {
        let title: String
        let message: String
        let perform: () -> Void
    }
    @Published var closeRequest: CloseRequest?

    let fleetStateDidChange = PassthroughSubject<FleetStateChange, Never>()

    private let store = DeviceStore()
    private var services: [UUID: HerdrService] = [:]
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var sessionTaskGenerations: [UUID: UInt64] = [:]
    private var refreshDebounces: [UUID: Task<Void, Never>] = [:]
    private var refreshWorkers: [UUID: Task<Void, Never>] = [:]
    private var refreshWorkerGenerations: [UUID: UInt64] = [:]
    private var dirtyRefreshes: Set<UUID> = []
    private var previousStatuses: [UUID: [String: AgentStatus]] = [:]
    private var hasStarted = false

    init() {
        let loaded = DeviceStore().load()
        devices = loaded
        // Restore the device filter only if that device still exists;
        // otherwise fall back to All Devices.
        if let raw = UserDefaults.standard.string(forKey: Self.deviceFilterKey),
           let id = UUID(uuidString: raw),
           loaded.contains(where: { $0.id == id }) {
            deviceFilter = id
        }
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
        let tabLabel: String?

        var id: String { "\(device.id.uuidString)-\(agent.paneID)" }
        var ref: PaneRef { PaneRef(deviceID: device.id, paneID: agent.paneID) }
        var title: String { agent.title(tabLabel: tabLabel) }
    }

    func agentEntry(device: Device, agent: AgentInfo) -> AgentEntry {
        AgentEntry(
            device: device,
            agent: agent,
            tabLabel: session(device.id).tabs.first { $0.tabID == agent.tabID }?.customLabel
        )
    }

    struct TerminalEntry: Identifiable {
        let device: Device
        let pane: PaneInfo
        let tab: TabInfo?
        let terminalID: String

        var id: String { "\(device.id.uuidString)-\(pane.paneID)" }
        var ref: PaneRef { PaneRef(deviceID: device.id, paneID: pane.paneID) }

        var title: String {
            if let terminalTitle = pane.terminalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !terminalTitle.isEmpty {
                return terminalTitle
            }
            if let label = tab?.customLabel {
                return label
            }
            if let cwd = pane.cwd, !cwd.isEmpty {
                let basename = URL(fileURLWithPath: cwd).lastPathComponent
                if !basename.isEmpty { return basename }
            }
            return String(localized: "Terminal")
        }
    }

    enum AttachedEntry: Identifiable {
        case agent(AgentEntry)
        case terminal(TerminalEntry)

        var id: String {
            switch self {
            case .agent(let entry): return "agent-\(entry.id)"
            case .terminal(let entry): return "terminal-\(entry.id)"
            }
        }

        var device: Device {
            switch self {
            case .agent(let entry): return entry.device
            case .terminal(let entry): return entry.device
            }
        }

        var ref: PaneRef {
            switch self {
            case .agent(let entry): return entry.ref
            case .terminal(let entry): return entry.ref
            }
        }

        var workspaceID: String {
            switch self {
            case .agent(let entry): return entry.agent.workspaceID
            case .terminal(let entry): return entry.pane.workspaceID
            }
        }

        var attachTarget: TerminalAttachTarget {
            switch self {
            case .agent(let entry): return .agent(paneID: entry.agent.paneID)
            case .terminal(let entry): return .terminal(terminalID: entry.terminalID)
            }
        }
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

    /// Agents across the scope, filtered by selected space, in herdr tab order
    /// (device → workspace → tab number) so sidebar drag matches the TUI.
    var visibleAgents: [AgentEntry] {
        var entries = devicesInScope.flatMap { device in
            session(device.id).agents.map { agentEntry(device: device, agent: $0) }
        }
        if let space = selectedSpace {
            entries = entries.filter {
                $0.device.id == space.deviceID && $0.agent.workspaceID == space.workspaceID
            }
        }
        let deviceRank = Dictionary(uniqueKeysWithValues: devicesInScope.enumerated().map { ($1.id, $0) })
        return entries.sorted { lhs, rhs in
            let d0 = deviceRank[lhs.device.id] ?? Int.max
            let d1 = deviceRank[rhs.device.id] ?? Int.max
            if d0 != d1 { return d0 < d1 }
            let w0 = workspaceRank(deviceID: lhs.device.id, workspaceID: lhs.agent.workspaceID)
            let w1 = workspaceRank(deviceID: rhs.device.id, workspaceID: rhs.agent.workspaceID)
            if w0 != w1 { return w0 < w1 }
            return tabRank(deviceID: lhs.device.id, tabID: lhs.agent.tabID)
                < tabRank(deviceID: rhs.device.id, tabID: rhs.agent.tabID)
        }
    }

    func terminalEntries(for device: Device) -> [TerminalEntry] {
        let state = session(device.id)
        let tabsByID = Dictionary(uniqueKeysWithValues: state.tabs.map { ($0.tabID, $0) })
        return state.panes.compactMap { pane in
            guard let terminalID = pane.terminalID else { return nil }
            return TerminalEntry(
                device: device,
                pane: pane,
                tab: pane.tabID.flatMap { tabsByID[$0] },
                terminalID: terminalID
            )
        }
    }

    var visibleTerminals: [TerminalEntry] {
        var entries = devicesInScope.flatMap { terminalEntries(for: $0) }
        if let space = selectedSpace {
            entries = entries.filter {
                $0.device.id == space.deviceID && $0.pane.workspaceID == space.workspaceID
            }
        }
        return entries
    }

    func isUnread(_ entry: AgentEntry) -> Bool {
        unreadAgents.contains(AgentUnreadKey(deviceID: entry.device.id, paneID: entry.agent.paneID))
    }

    func attention(in entry: SpaceEntry) -> SpaceAttention {
        let agents = session(entry.device.id).agents.filter {
            $0.workspaceID == entry.workspace.workspaceID
        }
        return SpaceAttention.rollup(agents.map {
            (
                status: $0.status,
                unreadDone: unreadAgents.contains(
                    AgentUnreadKey(deviceID: entry.device.id, paneID: $0.paneID)
                )
            )
        })
    }

    var scopeAttention: SpaceAttention {
        SpaceAttention.rollup(devicesInScope.flatMap { device in
            session(device.id).agents.map {
                (
                    status: $0.status,
                    unreadDone: unreadAgents.contains(
                        AgentUnreadKey(deviceID: device.id, paneID: $0.paneID)
                    )
                )
            }
        })
    }

    private func workspaceRank(deviceID: UUID, workspaceID: String) -> Int {
        session(deviceID).workspaces.firstIndex { $0.workspaceID == workspaceID } ?? Int.max
    }

    private func tabRank(deviceID: UUID, tabID: String) -> Int {
        session(deviceID).tabs.firstIndex { $0.tabID == tabID } ?? Int.max
    }

    private func orderedTabIDs(deviceID: UUID, workspaceID: String) -> [String] {
        session(deviceID).tabs
            .filter { $0.workspaceID == workspaceID }
            .map(\.tabID)
    }

    var scopeAgentCount: Int {
        devicesInScope.reduce(0) { $0 + session($1.id).agents.count }
    }

    var selectedEntry: AgentEntry? {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return nil }
        guard let agent = session(selected.deviceID).agents.first(where: { $0.paneID == selected.paneID })
        else { return nil }
        return agentEntry(device: device, agent: agent)
    }

    var selectedTerminalEntry: TerminalEntry? {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return nil }
        return terminalEntries(for: device).first { $0.pane.paneID == selected.paneID }
    }

    var selectedAttachedEntry: AttachedEntry? {
        if let selectedEntry { return .agent(selectedEntry) }
        if let selectedTerminalEntry { return .terminal(selectedTerminalEntry) }
        return nil
    }

    var attachedSpaceRef: SpaceRef? {
        guard selectedShellID == nil, !isFileManagerActive else { return nil }
        return selectedAttachedEntry.map {
            SpaceRef(deviceID: $0.device.id, workspaceID: $0.workspaceID)
        }
    }

    var spaceSplitSessions: [SpaceSplitSession] {
        splitSessionsBySpace.values.sorted {
            if $0.space.deviceID != $1.space.deviceID {
                return $0.space.deviceID.uuidString < $1.space.deviceID.uuidString
            }
            return $0.space.workspaceID < $1.space.workspaceID
        }
    }

    /// Restores the split owned by the selected Space, or closes the visual
    /// split without destroying shells owned by other Spaces.
    func activateSplitSession(for space: SpaceRef?) {
        restoringSplitSession = true
        defer { restoringSplitSession = false }
        guard let space, let session = splitSessionsBySpace[space] else {
            shellSplitAxis = nil
            activeSplitSide = .agent
            splitShellView = nil
            return
        }
        shellSplitAxis = session.axis
        activeSplitSide = session.activeSide
        splitRatio = session.ratio
        splitShellView = splitShellViews[space]?.view
    }

    func registerSplitShellView(_ view: LocalProcessTerminalView, for space: SpaceRef) {
        splitShellViews[space] = WeakTerminalViewBox(view)
        if attachedSpaceRef == space {
            splitShellView = view
        }
    }

    func closeSplitSession(for space: SpaceRef) {
        splitShellViews.removeValue(forKey: space)
        if attachedSpaceRef == space {
            shellSplitAxis = nil
            activeSplitSide = .agent
        } else {
            splitSessionsBySpace.removeValue(forKey: space)
        }
    }

    private func persistCurrentSplitSession() {
        guard !restoringSplitSession, let space = attachedSpaceRef else { return }
        guard let axis = shellSplitAxis else {
            splitSessionsBySpace.removeValue(forKey: space)
            splitShellViews.removeValue(forKey: space)
            splitShellView = nil
            return
        }
        if var session = splitSessionsBySpace[space] {
            session.axis = axis
            session.activeSide = activeSplitSide
            session.ratio = splitRatio
            splitSessionsBySpace[space] = session
        } else {
            splitSessionsBySpace[space] = SpaceSplitSession(
                id: UUID(),
                space: space,
                axis: axis,
                activeSide: activeSplitSide,
                ratio: splitRatio
            )
        }
        splitShellView = splitShellViews[space]?.view
    }

    private func pruneSplitSessions(deviceID: UUID, validWorkspaceIDs: Set<String>) {
        let stale = splitSessionsBySpace.keys.filter {
            $0.deviceID == deviceID && !validWorkspaceIDs.contains($0.workspaceID)
        }
        for space in stale {
            splitSessionsBySpace.removeValue(forKey: space)
            splitShellViews.removeValue(forKey: space)
        }
    }

    func agentDisplayKind(for entry: AgentEntry) -> String {
        isAtomicAgent(entry) ? "atomic" : entry.agent.agent
    }

    func agentDisplayStatus(for entry: AgentEntry) -> AgentStatus {
        let status = entry.agent.status
        if atomicWorkingPanes.contains(entry.ref) {
            return .working
        }
        return status
    }

    private func isAtomicAgent(_ entry: AgentEntry) -> Bool {
        if atomicPaneRefs.contains(entry.ref) { return true }
        let candidates: [String?] = [
            entry.tabLabel,
            entry.agent.name,
            entry.agent.customTitle,
            entry.agent.terminalTitleStripped,
            entry.agent.terminalTitle,
            entry.title,
        ]
        return candidates.compactMap { value in
            value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }.contains { value in
            value == "atomic" || value.hasPrefix("atomic-")
        }
    }

    func refreshAtomicActivity(for entry: AgentEntry) async {
        guard isAtomicAgent(entry),
              let read = try? await service(for: entry.device).readPane(paneID: entry.agent.paneID),
              !Task.isCancelled
        else { return }
        var next = atomicWorkingPanes
        if AtomicActivityDetector.isWorking(in: read.text) {
            next.insert(entry.ref)
        } else {
            next.remove(entry.ref)
        }
        if next != atomicWorkingPanes {
            atomicWorkingPanes = next
        }
    }

    func branchName(for entry: AgentEntry) -> String? {
        branchesByPane[entry.ref]
    }

    func refreshBranch(for entry: AgentEntry) async {
        guard let cwd = entry.agent.cwd, !cwd.isEmpty else {
            branchesByPane.removeValue(forKey: entry.ref)
            return
        }
        let branch = await service(for: entry.device).gitBranch(at: cwd)
        guard !Task.isCancelled else { return }
        if let branch, !branch.isEmpty {
            branchesByPane[entry.ref] = branch
        } else {
            branchesByPane.removeValue(forKey: entry.ref)
        }
    }

    private var firstVisiblePaneRef: PaneRef? {
        visibleAgents.first?.ref ?? visibleTerminals.first?.ref
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

    /// Badges on sidebar/titlebar rows are scoped by the device filter: with a
    /// single device selected every row belongs to it, so the badge says
    /// nothing. ⌘K search and the New Agent/Space device pickers stay on
    /// `showsDeviceBadges` — search crosses all devices regardless of the
    /// filter, and the pickers must stay reachable while filtered.
    var showsRowDeviceBadges: Bool {
        devices.count > 1 && deviceFilter == nil
    }

    // MARK: - Selection

    func selectSpace(_ ref: SpaceRef?) {
        isFileManagerActive = false
        selectedSpace = ref
        selectedShellID = nil
        if let entry = selectedAttachedEntry {
            if ref == nil { return }
            if entry.device.id == ref!.deviceID && entry.workspaceID == ref!.workspaceID { return }
        }
        selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
    }

    func setDeviceFilter(_ id: UUID?) {
        deviceFilter = id
        if let id, let space = selectedSpace, space.deviceID != id {
            selectedSpace = nil
        }
        if let id, let selected = selectedPane, selected.deviceID != id {
            selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
        }
    }

    /// When jumping into a space, land on whoever still needs a look — not
    /// merely the first tab.
    private func preferredVisibleAgent() -> AgentEntry? {
        let agents = visibleAgents
        if let blocked = agents.first(where: { $0.agent.status == .blocked }) { return blocked }
        if let unread = agents.first(where: { $0.agent.status == .done && isUnread($0) }) {
            return unread
        }
        if let working = agents.first(where: { $0.agent.status == .working }) { return working }
        return agents.first
    }

    /// Jump target used by the search sheet and by notification clicks.
    func reveal(_ ref: PaneRef) {
        isFileManagerActive = false
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

    func openFileManager() {
        isFileManagerActive = true
        selectedShellID = nil
    }

    func selectAgent(_ ref: PaneRef) {
        isFileManagerActive = false
        selectedPane = ref
        selectedShellID = nil
    }

    var selectedShell: ShellSession? {
        selectedShellID.flatMap { id in shellSessions.first { $0.id == id } }
    }

    /// Every click opens another terminal, like New Agent opens another agent.
    func newShellSession(on device: Device) {
        let n = shellSessions.count + 1
        let session = ShellSession(
            id: UUID(),
            title: String(localized: "Terminal \(n)"),
            device: device
        )
        shellSessions.append(session)
        selectShell(session.id)
    }

    func selectShell(_ id: UUID) {
        isFileManagerActive = false
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

    private func publishFleetChange(_ change: FleetStateChange) {
        fleetStateDidChange.send(change)
    }

    private func setConnection(_ connection: ConnectionState, for deviceID: UUID) {
        guard var state = sessions[deviceID], state.connection != connection else { return }
        state.connection = connection
        sessions[deviceID] = state
        publishFleetChange(.device(deviceID))
    }

    private func setAgentCatalog(_ catalog: AgentCatalogState, for deviceID: UUID) {
        guard var state = sessions[deviceID], state.agentCatalog != catalog else { return }
        state.agentCatalog = catalog
        sessions[deviceID] = state
        publishFleetChange(.device(deviceID))
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        NotificationManager.shared.setup(model: self)
        // Finder-launched apps have launchd's PATH. Capture the login +
        // interactive shell environment on a background thread once; New Agent
        // lookup, herdr spawn, and terminal attach all read the same snapshot.
        Task.detached(priority: .utility) {
            _ = await ShellEnvironment.ensure()
        }
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

    private func isCurrentSessionTask(
        deviceID: UUID,
        generation: UInt64,
        service: HerdrService
    ) -> Bool {
        !Task.isCancelled
            && sessionTaskGenerations[deviceID] == generation
            && services[deviceID] === service
            && sessions[deviceID] != nil
            && device(deviceID) != nil
    }

    private func isCurrentService(_ service: HerdrService, deviceID: UUID) -> Bool {
        !Task.isCancelled
            && services[deviceID] === service
            && sessions[deviceID] != nil
            && device(deviceID) != nil
    }

    /// Runs one device's session: connect, snapshot, event stream, and reconnect
    /// with exponential backoff (1s → 30s) whenever the connection drops.
    private func startSession(_ device: Device) {
        guard sessionTasks[device.id] == nil else { return }
        if sessions[device.id] == nil { sessions[device.id] = DeviceSessionState() }
        let service = service(for: device)
        let taskGeneration = (sessionTaskGenerations[device.id] ?? 0) &+ 1
        sessionTaskGenerations[device.id] = taskGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sessionTaskGenerations[device.id] == taskGeneration {
                    self.sessionTasks[device.id] = nil
                }
            }

            var backoff: Double = 1
            while self.isCurrentSessionTask(
                deviceID: device.id,
                generation: taskGeneration,
                service: service
            ) {
                self.setConnection(.connecting, for: device.id)
                do {
                    let pong = try await service.connect()
                    guard self.isCurrentSessionTask(
                        deviceID: device.id,
                        generation: taskGeneration,
                        service: service
                    ) else {
                        await service.disconnect()
                        return
                    }
                    self.setConnection(.connected(version: pong.version), for: device.id)
                    backoff = 1
                    // retried on every successful connect until it sticks (a fresh
                    // device's first probes can fail before its host key is known)
                    if let current = self.device(device.id) {
                        self.probeOSIfNeeded(current)
                    }
                    await self.refresh(device.id)
                    guard self.isCurrentSessionTask(
                        deviceID: device.id,
                        generation: taskGeneration,
                        service: service
                    ) else { return }
                    await self.loadAgentCatalog(deviceID: device.id, using: service)
                    guard self.isCurrentSessionTask(
                        deviceID: device.id,
                        generation: taskGeneration,
                        service: service
                    ) else { return }
                    let stream = try await service.events()
                    for try await _ in stream {
                        guard self.isCurrentSessionTask(
                            deviceID: device.id,
                            generation: taskGeneration,
                            service: service
                        ) else { return }
                        self.scheduleRefresh(device.id)
                    }
                } catch {
                    guard self.isCurrentSessionTask(
                        deviceID: device.id,
                        generation: taskGeneration,
                        service: service
                    ) else { return }
                    self.setConnection(.failed(error.localizedDescription), for: device.id)
                    if let target = device.sshTarget, Self.isSSHAuthenticationFailure(error) {
                        self.sshAuthenticationRequest = SSHAuthenticationRequest(
                            deviceID: device.id,
                            target: target
                        )
                        return
                    }
                }
                guard self.isCurrentSessionTask(
                    deviceID: device.id,
                    generation: taskGeneration,
                    service: service
                ) else { return }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 30)
            }
        }
        sessionTasks[device.id] = task
    }

    /// Locally, keeps only advertised CLIs whose binaries are on the login-shell
    /// search PATH (or a Settings override). SSH hosts keep their server-owned
    /// catalog; `agent.start` validates in the target pane instead. Manifests
    /// also feed the attachment-capability registry (paste path vs upload).
    private func loadAgentCatalog(deviceID: UUID, using service: HerdrService) async {
        guard isCurrentService(service, deviceID: deviceID) else { return }
        setAgentCatalog(.loading, for: deviceID)
        do {
            let manifests = try await service.agentManifests()
            guard isCurrentService(service, deviceID: deviceID),
                  var state = sessions[deviceID]
            else { return }
            state.attachmentCapabilities =
                AgentAttachmentCapabilityRegistry(manifests: manifests)
            sessions[deviceID] = state

            let advertised = manifests.map(\.agent)
            if device(deviceID)?.isLocal == true {
                let overrides = AgentBinaryOverrides.load()
                var found = await service.installedAgents(
                    from: advertised,
                    overrides: overrides
                )
                guard isCurrentService(service, deviceID: deviceID) else { return }
                if advertised.contains("pi") {
                    let atomic = await service.installedAgents(
                        from: ["atomic"],
                        overrides: overrides
                    ).first
                    guard isCurrentService(service, deviceID: deviceID) else { return }
                    if let atomic {
                        if let piIndex = found.firstIndex(where: { $0.kind == "pi" }) {
                            found.insert(atomic, at: piIndex + 1)
                        } else {
                            found.append(atomic)
                        }
                    }
                }
                setAgentCatalog(
                    .loaded(
                        kinds: found.map(\.kind),
                        paths: Dictionary(uniqueKeysWithValues: found.map { ($0.kind, $0.path) })
                    ),
                    for: deviceID
                )
            } else {
                var kinds = advertised
                var paths: [String: String] = [:]
                if let piIndex = kinds.firstIndex(of: "pi"), !kinds.contains("atomic") {
                    kinds.insert("atomic", at: piIndex + 1)
                    paths["atomic"] = "atomic"
                }
                setAgentCatalog(.loaded(kinds: kinds, paths: paths), for: deviceID)
            }
        } catch {
            guard isCurrentService(service, deviceID: deviceID) else { return }
            setAgentCatalog(.failed(error.localizedDescription), for: deviceID)
        }
    }

    func reloadAgentCatalog(deviceID: UUID) {
        guard let device = device(deviceID) else { return }
        let service = service(for: device)
        Task { await loadAgentCatalog(deviceID: deviceID, using: service) }
    }

    /// Tears down every live tunnel. Awaited from the app's terminate hook — `stopSession`
    /// fires its disconnect in a detached `Task`, which never runs when the process is exiting.
    func shutdownAllSessions() async {
        let live = services
        services.removeAll()
        sessionTasks.values.forEach { $0.cancel() }
        sessionTasks.removeAll()
        sessionTaskGenerations.removeAll()
        refreshDebounces.values.forEach { $0.cancel() }
        refreshDebounces.removeAll()
        refreshWorkers.values.forEach { $0.cancel() }
        refreshWorkers.removeAll()
        refreshWorkerGenerations.removeAll()
        dirtyRefreshes.removeAll()
        hasStarted = false
        for service in live.values {
            await service.disconnect()
        }
    }

    private func stopSession(_ id: UUID) {
        sessionTaskGenerations[id] = (sessionTaskGenerations[id] ?? 0) &+ 1
        sessionTasks[id]?.cancel()
        sessionTasks[id] = nil
        refreshDebounces[id]?.cancel()
        refreshDebounces[id] = nil
        refreshWorkerGenerations[id] = (refreshWorkerGenerations[id] ?? 0) &+ 1
        refreshWorkers[id]?.cancel()
        refreshWorkers[id] = nil
        dirtyRefreshes.remove(id)
        previousStatuses[id] = nil
        let service = services[id]
        services[id] = nil
        sessions[id] = nil
        publishFleetChange(.device(id))
        Task { await service?.disconnect() }
    }

    func addDevice(name: String, sshTarget: String) {
        let device = Device(name: name, kind: .ssh(target: sshTarget))
        devices.append(device)
        store.save(devices)
        publishFleetChange(.topology)
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
        setConnection(
            .failed(String(localized: "Authentication cancelled — choose Reconnect to try again")),
            for: request.deviceID
        )
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
        publishFleetChange(.topology)
    }

    func removeDevice(_ device: Device) {
        guard !device.isLocal else { return }
        removeSSHPassword(for: device.id)
        if sshAuthenticationRequest?.deviceID == device.id { sshAuthenticationRequest = nil }
        pruneSplitSessions(deviceID: device.id, validWorkspaceIDs: [])
        stopSession(device.id)
        devices.removeAll { $0.id == device.id }
        store.save(devices)
        publishFleetChange(.topology)
        if deviceFilter == device.id { deviceFilter = nil }
        if selectedSpace?.deviceID == device.id { selectedSpace = nil }
        if selectedPane?.deviceID == device.id {
            selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
        }
    }

    // MARK: - Refresh

    func refresh(_ deviceID: UUID) async {
        guard device(deviceID) != nil,
              services[deviceID] != nil,
              sessions[deviceID] != nil
        else { return }
        dirtyRefreshes.insert(deviceID)
        refreshDebounces[deviceID]?.cancel()
        refreshDebounces[deviceID] = nil
        let worker = refreshWorkers[deviceID] ?? startRefreshWorker(deviceID)
        await worker.value
    }

    private func startRefreshWorker(_ deviceID: UUID) -> Task<Void, Never> {
        let workerGeneration = (refreshWorkerGenerations[deviceID] ?? 0) &+ 1
        refreshWorkerGenerations[deviceID] = workerGeneration
        let worker = Task { [weak self] in
            guard let self else { return }
            await self.runRefreshLoop(
                deviceID,
                workerGeneration: workerGeneration
            )
        }
        refreshWorkers[deviceID] = worker
        return worker
    }

    private func runRefreshLoop(
        _ deviceID: UUID,
        workerGeneration: UInt64
    ) async {
        while !Task.isCancelled {
            guard dirtyRefreshes.remove(deviceID) != nil else { break }
            await performRefresh(
                deviceID,
                workerGeneration: workerGeneration
            )
        }
        if refreshWorkerGenerations[deviceID] == workerGeneration {
            refreshWorkers[deviceID] = nil
        }
    }

    private func performRefresh(
        _ deviceID: UUID,
        workerGeneration: UInt64
    ) async {
        guard let device = device(deviceID), let service = services[deviceID] else { return }
        do {
            let snapshot = try await service.snapshot()
            guard !Task.isCancelled,
                  refreshWorkerGenerations[deviceID] == workerGeneration,
                  services[deviceID] === service,
                  sessions[deviceID] != nil
            else { return }
            let tabs = Self.orderedTabs(
                snapshot.tabs ?? [],
                workspaces: snapshot.workspaces
            )
            let panes = snapshot.ordinaryTerminalPanes
            let current = sessions[deviceID] ?? DeviceSessionState()
            let exportedStateChanged = current.agents != snapshot.agents
                || current.workspaces != snapshot.workspaces
                || current.tabs != tabs
                || current.panes != panes

            if exportedStateChanged {
                unreadAgents = AgentUnread.applying(
                    previous: previousStatuses[deviceID] ?? [:],
                    agents: snapshot.agents,
                    unread: unreadAgents,
                    deviceID: device.id
                )
                notifyTransitions(
                    device: device,
                    from: previousStatuses[deviceID] ?? [:],
                    to: snapshot.agents,
                    workspaces: snapshot.workspaces,
                    tabs: tabs
                )
                previousStatuses[deviceID] = Dictionary(
                    uniqueKeysWithValues: snapshot.agents.map { ($0.paneID, $0.status) }
                )

                var next = current
                next.agents = snapshot.agents
                next.workspaces = snapshot.workspaces
                next.tabs = tabs
                next.panes = panes
                sessions[deviceID] = next
                publishFleetChange(.device(deviceID))
            }

            pruneSplitSessions(
                deviceID: deviceID,
                validWorkspaceIDs: Set(snapshot.workspaces.map(\.workspaceID))
            )
            let paneIDs = Set((snapshot.panes ?? []).map(\.paneID))
                .union(snapshot.agents.map(\.paneID))
            if let selected = selectedPane, selected.deviceID == deviceID,
               !paneIDs.contains(selected.paneID) {
                selectedPane = nil
            }
            if let space = selectedSpace, space.deviceID == deviceID,
               !snapshot.workspaces.contains(where: { $0.workspaceID == space.workspaceID }) {
                selectedSpace = nil
            }
            if selectedPane == nil {
                if let focusedPaneID = snapshot.focusedPaneID,
                   paneIDs.contains(focusedPaneID),
                   deviceFilter == nil || deviceFilter == deviceID {
                    let focused = PaneRef(deviceID: deviceID, paneID: focusedPaneID)
                    if selectedSpace == nil
                        || selectedAttachedEntry.map({
                            $0.ref == focused && $0.workspaceID == selectedSpace?.workspaceID
                        }) == true {
                        selectedPane = focused
                    }
                }
                if selectedPane == nil {
                    selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
                }
            }
        } catch {
            guard !Task.isCancelled,
                  refreshWorkerGenerations[deviceID] == workerGeneration,
                  services[deviceID] === service,
                  sessions[deviceID] != nil
            else { return }
            setConnection(.failed(error.localizedDescription), for: deviceID)
        }
    }

    private func scheduleRefresh(_ deviceID: UUID) {
        guard device(deviceID) != nil,
              services[deviceID] != nil,
              sessions[deviceID] != nil
        else { return }
        dirtyRefreshes.insert(deviceID)
        guard refreshWorkers[deviceID] == nil else { return }
        refreshDebounces[deviceID]?.cancel()
        refreshDebounces[deviceID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.refreshDebounces[deviceID] = nil
            guard self.refreshWorkers[deviceID] == nil else { return }
            let worker = self.startRefreshWorker(deviceID)
            await worker.value
        }
    }

    /// Notifies when an agent newly becomes blocked (needs input) or done (finished
    /// while unwatched). Initial snapshots don't notify — only real transitions do.
    private func notifyTransitions(
        device: Device,
        from previous: [String: AgentStatus],
        to agents: [AgentInfo],
        workspaces: [WorkspaceInfo],
        tabs: [TabInfo]
    ) {
        guard !previous.isEmpty else { return }
        for agent in agents {
            guard let old = previous[agent.paneID], old != agent.status else { continue }
            guard agent.status == .blocked || agent.status == .done else { continue }
            let tabLabel = tabs.first { $0.tabID == agent.tabID }?.customLabel
            NotificationManager.shared.post(
                agent: agent,
                title: agent.title(tabLabel: tabLabel),
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
                self.publishFleetChange(.device(device.id))
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
            return String(localized: "Still connecting to \(device.name) — try again in a moment.")
        case .failed(let reason):
            return String(localized: "\(device.name) is unreachable: \(reason)")
        case .idle:
            return String(localized: "\(device.name) isn't connected.")
        case .connected:
            return String(localized: "\(device.name) just reconnected — try again.")
        }
    }

    // MARK: - Closing

    func requestCloseSpace(_ entry: SpaceEntry) {
        closeRequest = CloseRequest(
            title: String(localized: "Close space \"\(entry.workspace.label)\" on \(entry.device.name)?"),
            message: String(localized: "All terminals and agents in this space will be closed.")
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
            title: String(localized: "Close \"\(name)\"?"),
            message: String(localized: "The pane and whatever is running inside it will be terminated.")
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

    func renameAgent(_ entry: AgentEntry, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != entry.title else { return }
        Task {
            do {
                try await service(for: entry.device).renameTab(
                    tabID: entry.agent.tabID,
                    label: name
                )
                await refresh(entry.device.id)
            } catch {
                actionError = actionErrorMessage(error, device: entry.device)
            }
        }
    }

    /// Reorders a Space by dropping it on another Space of the same device.
    /// Cross-device drops are ignored; herdr remains the source of truth after refresh.
    func moveSpace(_ source: SpaceEntry, onto target: SpaceEntry, placeAfter: Bool) {
        guard source.device.id == target.device.id else { return }
        let orderedIDs = session(source.device.id).workspaces.map(\.workspaceID)
        guard let plan = WorkspaceReorder.plan(
            moving: source.workspace.workspaceID,
            onto: target.workspace.workspaceID,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }

        if let current = sessions[source.device.id]?.workspaces {
            sessions[source.device.id]?.workspaces = WorkspaceReorder.applying(
                current,
                id: \.workspaceID,
                plan: plan
            )
            publishFleetChange(.device(source.device.id))
        }

        Task {
            do {
                try await service(for: source.device).moveWorkspaceBlock(
                    workspaceIDs: plan.workspaceIDs,
                    beforeWorkspaceID: plan.beforeWorkspaceID
                )
                await refresh(source.device.id)
            } catch {
                await refresh(source.device.id)
                actionError = actionErrorMessage(error, device: source.device)
            }
        }
    }

    /// Reorders an agent tab by dropping it on another agent in the same space.
    /// Cross-space and cross-device drops are ignored (`tab.move` is in-workspace).
    func moveAgent(_ source: AgentEntry, onto target: AgentEntry, placeAfter: Bool) {
        guard source.device.id == target.device.id,
              source.agent.workspaceID == target.agent.workspaceID
        else { return }
        let orderedIDs = orderedTabIDs(
            deviceID: source.device.id,
            workspaceID: source.agent.workspaceID
        )
        guard let insertIndex = TabReorder.insertIndex(
            moving: source.agent.tabID,
            onto: target.agent.tabID,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }
        guard let plan = WorkspaceReorder.plan(
            moving: source.agent.tabID,
            onto: target.agent.tabID,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }

        if let current = sessions[source.device.id]?.tabs {
            let scoped = current.filter { $0.workspaceID == source.agent.workspaceID }
            let reordered = WorkspaceReorder.applying(scoped, id: \.tabID, plan: plan)
            sessions[source.device.id]?.tabs = Self.replacingTabs(
                current,
                workspaceID: source.agent.workspaceID,
                with: reordered
            )
            publishFleetChange(.device(source.device.id))
        }

        Task {
            do {
                try await service(for: source.device).moveTab(
                    tabID: source.agent.tabID,
                    insertIndex: insertIndex
                )
                await refresh(source.device.id)
            } catch {
                await refresh(source.device.id)
                actionError = actionErrorMessage(error, device: source.device)
            }
        }
    }

    private static func orderedTabs(_ tabs: [TabInfo], workspaces: [WorkspaceInfo]) -> [TabInfo] {
        let wsIndex = Dictionary(uniqueKeysWithValues: workspaces.enumerated().map {
            ($1.workspaceID, $0)
        })
        return tabs.sorted {
            let w0 = wsIndex[$0.workspaceID] ?? Int.max
            let w1 = wsIndex[$1.workspaceID] ?? Int.max
            if w0 != w1 { return w0 < w1 }
            return ($0.number ?? Int.max) < ($1.number ?? Int.max)
        }
    }

    private static func replacingTabs(
        _ tabs: [TabInfo],
        workspaceID: String,
        with reordered: [TabInfo]
    ) -> [TabInfo] {
        var result: [TabInfo] = []
        var inserted = false
        for tab in tabs {
            if tab.workspaceID == workspaceID {
                if !inserted {
                    result.append(contentsOf: reordered)
                    inserted = true
                }
            } else {
                result.append(tab)
            }
        }
        if !inserted { result.append(contentsOf: reordered) }
        return result
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

    /// Creates a persistent shell tab on the selected Herdr device. Local and
    /// remote terminals use the same server-owned lifecycle and can be detached
    /// and reattached without killing the shell process.
    func startNewTerminal(device: Device, workspaceID: String) {
        Task {
            do {
                let paneID = try await service(for: device).createTab(
                    workspaceID: workspaceID,
                    cwd: nil,
                    label: nil
                )
                await refresh(device.id)
                isFileManagerActive = false
                selectedSpace = SpaceRef(deviceID: device.id, workspaceID: workspaceID)
                selectedPane = PaneRef(deviceID: device.id, paneID: paneID)
                selectedShellID = nil
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
                if kind == "atomic" {
                    let binary = session(device.id).agentCatalog.paths[kind]
                        ?? HerdrService.binaryName(for: kind)
                    try await service.startPiCompatibleAgent(
                        executable: binary,
                        paneID: pane,
                        args: args,
                        waitForShell: true
                    )
                    atomicPaneRefs.insert(PaneRef(deviceID: device.id, paneID: pane))
                } else {
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
                }
                await refresh(device.id)
                isFileManagerActive = false
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
