import Foundation
import HerdrKit
import Observation

/// Connection state shown for either a paired Mac bridge or a direct SSH host.
enum MobileConnectionState: Equatable {
    case idle
    case connecting
    case connected(version: String)
    case failed(String)
}

enum MobileSourceID: Hashable {
    case bridge(UUID)
    case direct(UUID)
}

struct MobileSpaceEntry: Identifiable {
    let device: FleetDeviceDescriptor
    let workspace: WorkspaceInfo

    var ref: FleetSpaceRef {
        FleetSpaceRef(deviceID: device.id, workspaceID: workspace.workspaceID)
    }
    var id: FleetSpaceRef { ref }
}

struct MobileAgentEntry: Identifiable {
    let device: FleetDeviceDescriptor
    let agent: AgentInfo
    let tabLabel: String?

    var ref: FleetPaneRef {
        FleetPaneRef(deviceID: device.id, paneID: agent.paneID)
    }
    var id: FleetPaneRef { ref }
    var title: String { agent.title(tabLabel: tabLabel) }
}

struct MobileTerminalEntry: Identifiable {
    let device: FleetDeviceDescriptor
    let pane: PaneInfo
    let tabLabel: String?

    var ref: FleetPaneRef {
        FleetPaneRef(deviceID: device.id, paneID: pane.paneID)
    }
    var id: FleetPaneRef { ref }

    var title: String {
        if let terminalTitle = pane.terminalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalTitle.isEmpty {
            return terminalTitle
        }
        if let tabLabel { return tabLabel }
        if let cwd = pane.cwd, !cwd.isEmpty {
            let basename = URL(fileURLWithPath: cwd).lastPathComponent
            if !basename.isEmpty { return basename }
        }
        return String(localized: "Terminal")
    }
}

/// One directly configured SSH device. This remains an advanced fallback for
/// reaching a standalone Herdr host without a Mac fleet bridge.
@MainActor
final class MobileDeviceSession {
    let device: MobileDevice
    var state: MobileConnectionState = .idle
    var snapshot: SessionSnapshot?
    private(set) var transport: MobileTransport?
    private var eventTask: Task<Void, Never>?
    private var refreshPending = false

    var onChange: (() -> Void)?

    init(device: MobileDevice) {
        self.device = device
    }

    func connect() async {
        switch state {
        case .connecting, .connected:
            return
        case .idle, .failed:
            break
        }

        eventTask?.cancel()
        eventTask = nil
        if let existing = transport {
            await existing.close()
            transport = nil
        }
        state = .connecting
        onChange?()
        do {
            let transport = try await SSHDirectTransport.connect(device: device)
            let pong = try await transport.request(
                method: "ping", params: .object([:]), as: PingResult.self
            )
            guard pong.protocolVersion >= 17 else {
                await transport.close()
                throw HerdrError.incompatibleProtocol(pong.protocolVersion)
            }
            self.transport = transport
            state = .connected(version: pong.version)
            await refresh()
            startEventPump()
        } catch {
            transport = nil
            state = .failed(Self.presentation(error))
        }
        onChange?()
    }

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        if let transport { await transport.close() }
        transport = nil
        state = .idle
        onChange?()
    }

    func refresh() async {
        guard let transport else { return }
        struct Envelope: Codable { let snapshot: SessionSnapshot }
        do {
            snapshot = try await transport.request(
                method: "session.snapshot", as: Envelope.self
            ).snapshot
            onChange?()
        } catch {
            // Keep the last useful snapshot. The event stream decides whether
            // the underlying connection is gone.
        }
    }

    private func startEventPump() {
        guard let transport else { return }
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            do {
                for try await _ in transport.events(kinds: HerdrEvent.allKinds) {
                    await self?.scheduleRefresh()
                }
            } catch {}
            guard let self, !Task.isCancelled else { return }
            if case .connected = self.state {
                self.state = .failed(String(localized: "Connection lost"))
                self.onChange?()
            }
        }
    }

    private func scheduleRefresh() async {
        guard !refreshPending else { return }
        refreshPending = true
        try? await Task.sleep(for: .milliseconds(300))
        refreshPending = false
        await refresh()
    }

    private static func presentation(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

/// Long-lived subscription to one paired Mac's aggregate fleet. It reconnects
/// with backoff and always accepts a complete snapshot after reconnect.
@MainActor
final class MobileBridgeHostSession {
    let endpoint: MobileBridgeEndpoint
    var state: MobileConnectionState = .idle
    var snapshot: FleetSnapshot?
    var onChange: (() -> Void)?

    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(endpoint: MobileBridgeEndpoint) {
        self.endpoint = endpoint
    }

    func connect() {
        if task != nil {
            if case .failed = state {
                task?.cancel()
                task = nil
            } else {
                return
            }
        }
        guard let token = MobileBridgeSecretStore.token(for: endpoint.id) else {
            state = .failed(String(localized: "This Mac has no saved pairing token."))
            onChange?()
            return
        }

        generation &+= 1
        let currentGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == currentGeneration {
                    self.task = nil
                }
            }
            var backoff: Double = 1
            while !Task.isCancelled, self.generation == currentGeneration {
                self.state = .connecting
                self.onChange?()
                do {
                    let stream = MobileBridgeClient.snapshots(
                        endpoint: self.endpoint,
                        token: token,
                        afterRevision: self.snapshot?.revision
                    )
                    for try await snapshot in stream {
                        backoff = 1
                        self.snapshot = snapshot
                        self.state = .connected(version: "bridge")
                        self.onChange?()
                    }
                    if !Task.isCancelled {
                        throw MobileBridgeClientError.connectionClosed
                    }
                } catch {
                    guard !Task.isCancelled else { break }
                    self.state = .failed(Self.presentation(error))
                    self.onChange?()
                }
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    func refresh() async {
        guard let token = MobileBridgeSecretStore.token(for: endpoint.id) else { return }
        do {
            snapshot = try await MobileBridgeClient.snapshot(endpoint: endpoint, token: token)
            state = .connected(version: "bridge")
            onChange?()
        } catch {
            state = .failed(Self.presentation(error))
            onChange?()
        }
    }

    func disconnect() {
        generation &+= 1
        task?.cancel()
        task = nil
        state = .idle
        onChange?()
    }

    private static func presentation(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

@MainActor
@Observable
final class MobileAppModel {
    var bridgeHosts: [MobileBridgeEndpoint] = []
    var directDevices: [MobileDevice] = []
    var selectedSourceID: MobileSourceID?
    var selectedFleetDeviceID: UUID?
    var selectedSpaceRef: FleetSpaceRef?
    var selectedPaneRef: FleetPaneRef?
    var showAddBridge = false
    var showAddDevice = false
    private(set) var revision = 0

    private let bridgeStore = MobileBridgeStore()
    private let deviceStore = MobileDeviceStore()
    private var bridgeSessions: [UUID: MobileBridgeHostSession] = [:]
    private var directSessions: [UUID: MobileDeviceSession] = [:]
    private var bridgeTransports: [UUID: BridgeDeviceTransport] = [:]

    init() {
        bridgeHosts = bridgeStore.load()
        directDevices = deviceStore.load()
        if let bridge = bridgeHosts.first {
            selectedSourceID = .bridge(bridge.id)
            selectedFleetDeviceID = nil
        } else if let device = directDevices.first {
            selectedSourceID = .direct(device.id)
            selectedFleetDeviceID = device.id
        }
    }

    // MARK: - Source lifecycle

    var hasSources: Bool { !bridgeHosts.isEmpty || !directDevices.isEmpty }

    var selectedBridge: MobileBridgeEndpoint? {
        guard case .bridge(let id)? = selectedSourceID else { return nil }
        return bridgeHosts.first { $0.id == id }
    }

    var selectedDirectDevice: MobileDevice? {
        guard case .direct(let id)? = selectedSourceID else { return nil }
        return directDevices.first { $0.id == id }
    }

    var selectedSourceName: String {
        selectedBridge?.name ?? selectedDirectDevice?.name ?? String(localized: "No Connection")
    }

    var selectedSourceSubtitle: String {
        selectedBridge?.subtitle ?? selectedDirectDevice?.subtitle ?? ""
    }

    var selectedSourceIsBridge: Bool { selectedBridge != nil }

    var selectedSourceConnectionState: MobileConnectionState {
        _ = revision
        switch selectedSourceID {
        case .bridge(let id): return bridgeSession(for: id)?.state ?? .idle
        case .direct(let id): return directSession(for: id)?.state ?? .idle
        case nil: return .idle
        }
    }

    func activate() {
        connectSelectedSource()
    }

    func connectSelectedSource() {
        switch selectedSourceID {
        case .bridge(let id): bridgeSession(for: id)?.connect()
        case .direct(let id):
            guard let session = directSession(for: id) else { return }
            Task { await session.connect() }
        case nil: break
        }
    }

    func refreshActive() async {
        switch selectedSourceID {
        case .bridge(let id): await bridgeSession(for: id)?.refresh()
        case .direct(let id): await directSession(for: id)?.refresh()
        case nil: break
        }
    }

    func selectBridge(_ id: UUID) {
        if selectedSourceID == .bridge(id) {
            bridgeSession(for: id)?.connect()
            return
        }
        selectedSourceID = .bridge(id)
        selectedFleetDeviceID = nil
        selectedSpaceRef = nil
        selectedPaneRef = nil
        bridgeTransports.removeAll()
        connectSelectedSource()
    }

    func selectDirectDevice(_ id: UUID) {
        if selectedSourceID == .direct(id) {
            guard let session = directSession(for: id) else { return }
            Task { await session.connect() }
            return
        }
        selectedSourceID = .direct(id)
        selectedFleetDeviceID = id
        selectedSpaceRef = nil
        selectedPaneRef = nil
        bridgeTransports.removeAll()
        connectSelectedSource()
    }

    func selectFleetDevice(_ id: UUID?) {
        guard id != selectedFleetDeviceID else { return }
        selectedFleetDeviceID = id
        selectedSpaceRef = nil
        selectedPaneRef = nil
    }

    // MARK: - Source management

    func addBridge(
        name: String,
        host: String,
        port: UInt16,
        token: String,
        serverID: UUID? = nil
    ) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var endpoint = MobileBridgeEndpoint(
            serverID: serverID,
            name: trimmedName.isEmpty ? trimmedHost : trimmedName,
            host: trimmedHost,
            port: port
        )
        if let serverID,
           let index = bridgeHosts.firstIndex(where: { $0.serverID == serverID }) {
            endpoint.id = bridgeHosts[index].id
            bridgeSessions[endpoint.id]?.disconnect()
            bridgeSessions.removeValue(forKey: endpoint.id)
            bridgeHosts[index] = endpoint
        } else {
            bridgeHosts.append(endpoint)
        }
        MobileBridgeSecretStore.setToken(
            token.trimmingCharacters(in: .whitespacesAndNewlines),
            for: endpoint.id
        )
        bridgeStore.save(bridgeHosts)
        bridgeTransports.removeAll()
        selectBridge(endpoint.id)
    }

    func addDirectDevice(
        name: String,
        host: String,
        port: UInt16,
        username: String,
        authMethod: MobileDevice.AuthMethod,
        password: String
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = MobileDevice(
            name: trimmedName.isEmpty ? host : trimmedName,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: authMethod
        )
        if authMethod == .password {
            MobileSecretStore.setPassword(password, for: device.id)
        }
        directDevices.append(device)
        deviceStore.save(directDevices)
        selectDirectDevice(device.id)
    }

    var deviceKeyAuthorizedLine: String {
        DeviceKey.authorizedKeysLine(DeviceKey.ensure())
    }

    func removeSelectedSource() {
        switch selectedSourceID {
        case .bridge(let id): removeBridge(id)
        case .direct(let id): removeDirectDevice(id)
        case nil: break
        }
    }

    private func removeBridge(_ id: UUID) {
        bridgeSessions.removeValue(forKey: id)?.disconnect()
        MobileBridgeSecretStore.removeToken(for: id)
        bridgeHosts.removeAll { $0.id == id }
        bridgeStore.save(bridgeHosts)
        chooseFallbackSource()
    }

    private func removeDirectDevice(_ id: UUID) {
        if let session = directSessions.removeValue(forKey: id) {
            Task { await session.disconnect() }
        }
        if let device = directDevices.first(where: { $0.id == id }) {
            MobileSecretStore.removePassword(for: id)
            KnownHostsStore.unpin(host: device.host, port: device.port)
        }
        directDevices.removeAll { $0.id == id }
        deviceStore.save(directDevices)
        chooseFallbackSource()
    }

    private func chooseFallbackSource() {
        selectedSpaceRef = nil
        selectedPaneRef = nil
        bridgeTransports.removeAll()
        if let bridge = bridgeHosts.first {
            selectedSourceID = .bridge(bridge.id)
            selectedFleetDeviceID = nil
        } else if let device = directDevices.first {
            selectedSourceID = .direct(device.id)
            selectedFleetDeviceID = device.id
        } else {
            selectedSourceID = nil
            selectedFleetDeviceID = nil
        }
        connectSelectedSource()
    }

    // MARK: - Fleet projection

    var fleetDevices: [FleetDeviceSnapshot] {
        _ = revision
        switch selectedSourceID {
        case .bridge(let id):
            return bridgeSession(for: id)?.snapshot?.devices ?? []
        case .direct(let id):
            guard let device = directDevices.first(where: { $0.id == id }),
                  let session = directSession(for: id)
            else { return [] }
            return [FleetDeviceSnapshot(
                device: FleetDeviceDescriptor(
                    id: device.id,
                    name: device.name,
                    subtitle: device.subtitle,
                    isLocal: false
                ),
                connection: fleetConnection(session.state),
                snapshot: session.snapshot
            )]
        case nil:
            return []
        }
    }

    var scopedDevices: [FleetDeviceSnapshot] {
        if let selectedFleetDeviceID {
            return fleetDevices.filter { $0.id == selectedFleetDeviceID }
        }
        return fleetDevices
    }

    var showsDeviceBadges: Bool { fleetDevices.count > 1 }

    var spaces: [MobileSpaceEntry] {
        scopedDevices.flatMap { device in
            (device.snapshot?.workspaces ?? []).map {
                MobileSpaceEntry(device: device.device, workspace: $0)
            }
        }
    }

    var agents: [MobileAgentEntry] {
        var entries = scopedDevices.flatMap { device -> [MobileAgentEntry] in
            let tabs = Dictionary(uniqueKeysWithValues:
                (device.snapshot?.tabs ?? []).compactMap { tab in
                    tab.customLabel.map { (tab.tabID, $0) }
                }
            )
            return (device.snapshot?.agents ?? []).map { agent in
                MobileAgentEntry(
                    device: device.device,
                    agent: agent,
                    tabLabel: tabs[agent.tabID]
                )
            }
        }
        if let selectedSpaceRef {
            entries = entries.filter {
                $0.device.id == selectedSpaceRef.deviceID
                    && $0.agent.workspaceID == selectedSpaceRef.workspaceID
            }
        }
        let deviceRank = Dictionary(uniqueKeysWithValues:
            fleetDevices.enumerated().map { ($1.id, $0) }
        )
        return entries.sorted { lhs, rhs in
            if lhs.agent.status.sortBucket != rhs.agent.status.sortBucket {
                return lhs.agent.status.sortBucket < rhs.agent.status.sortBucket
            }
            let leftRank = deviceRank[lhs.device.id] ?? Int.max
            let rightRank = deviceRank[rhs.device.id] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.agent.paneID < rhs.agent.paneID
        }
    }

    var terminals: [MobileTerminalEntry] {
        var entries = scopedDevices.flatMap { device -> [MobileTerminalEntry] in
            guard let snapshot = device.snapshot else { return [] }
            let tabs = Dictionary(uniqueKeysWithValues:
                (snapshot.tabs ?? []).compactMap { tab in
                    tab.customLabel.map { (tab.tabID, $0) }
                }
            )
            return snapshot.ordinaryTerminalPanes.map { pane in
                MobileTerminalEntry(
                    device: device.device,
                    pane: pane,
                    tabLabel: pane.tabID.flatMap { tabs[$0] }
                )
            }
        }
        if let selectedSpaceRef {
            entries = entries.filter {
                $0.device.id == selectedSpaceRef.deviceID
                    && $0.pane.workspaceID == selectedSpaceRef.workspaceID
            }
        }
        return entries.sorted {
            if $0.device.id != $1.device.id {
                return $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending
            }
            return $0.pane.paneID < $1.pane.paneID
        }
    }

    var selectedAgentEntry: MobileAgentEntry? {
        guard let selectedPaneRef else { return nil }
        return agents.first { $0.ref == selectedPaneRef }
            ?? allAgentEntries.first { $0.ref == selectedPaneRef }
    }

    var selectedTerminalEntry: MobileTerminalEntry? {
        guard let selectedPaneRef else { return nil }
        return terminals.first { $0.ref == selectedPaneRef }
            ?? allTerminalEntries.first { $0.ref == selectedPaneRef }
    }

    func selectSpace(_ ref: FleetSpaceRef?) {
        selectedSpaceRef = ref
        if let selectedPaneRef,
           let ref,
           selectedPaneRef.deviceID != ref.deviceID {
            self.selectedPaneRef = nil
        }
    }

    func spaceName(deviceID: UUID, workspaceID: String) -> String {
        fleetDevices.first { $0.id == deviceID }?.snapshot?.workspaces
            .first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }

    func transport(for deviceID: UUID) -> MobileTransport? {
        switch selectedSourceID {
        case .bridge(let bridgeID):
            guard let endpoint = bridgeHosts.first(where: { $0.id == bridgeID }),
                  let token = MobileBridgeSecretStore.token(for: bridgeID)
            else { return nil }
            if let existing = bridgeTransports[deviceID] { return existing }
            let transport = BridgeDeviceTransport(
                endpoint: endpoint,
                deviceID: deviceID,
                token: token
            )
            bridgeTransports[deviceID] = transport
            return transport
        case .direct(let id) where id == deviceID:
            return directSession(for: id)?.transport
        default:
            return nil
        }
    }

    func connectionState(for deviceID: UUID) -> MobileConnectionState {
        guard let device = fleetDevices.first(where: { $0.id == deviceID }) else { return .idle }
        return mobileConnection(device.connection)
    }

    // MARK: - Sessions

    private func bridgeSession(for id: UUID) -> MobileBridgeHostSession? {
        if let existing = bridgeSessions[id] { return existing }
        guard let endpoint = bridgeHosts.first(where: { $0.id == id }) else { return nil }
        let session = MobileBridgeHostSession(endpoint: endpoint)
        session.onChange = { [weak self] in self?.revision += 1 }
        bridgeSessions[id] = session
        return session
    }

    private func directSession(for id: UUID) -> MobileDeviceSession? {
        if let existing = directSessions[id] { return existing }
        guard let device = directDevices.first(where: { $0.id == id }) else { return nil }
        let session = MobileDeviceSession(device: device)
        session.onChange = { [weak self] in self?.revision += 1 }
        directSessions[id] = session
        return session
    }

    private var allAgentEntries: [MobileAgentEntry] {
        fleetDevices.flatMap { device -> [MobileAgentEntry] in
            let tabs = Dictionary(uniqueKeysWithValues:
                (device.snapshot?.tabs ?? []).compactMap { tab in
                    tab.customLabel.map { (tab.tabID, $0) }
                }
            )
            return (device.snapshot?.agents ?? []).map {
                MobileAgentEntry(
                    device: device.device,
                    agent: $0,
                    tabLabel: tabs[$0.tabID]
                )
            }
        }
    }

    private var allTerminalEntries: [MobileTerminalEntry] {
        fleetDevices.flatMap { device -> [MobileTerminalEntry] in
            guard let snapshot = device.snapshot else { return [] }
            let tabs = Dictionary(uniqueKeysWithValues:
                (snapshot.tabs ?? []).compactMap { tab in
                    tab.customLabel.map { (tab.tabID, $0) }
                }
            )
            return snapshot.ordinaryTerminalPanes.map {
                MobileTerminalEntry(
                    device: device.device,
                    pane: $0,
                    tabLabel: $0.tabID.flatMap { tabs[$0] }
                )
            }
        }
    }

    private func fleetConnection(_ state: MobileConnectionState) -> FleetConnectionInfo {
        switch state {
        case .idle: return .idle
        case .connecting: return .connecting
        case .connected(let version): return .connected(version: version)
        case .failed(let message): return .failed(message)
        }
    }

    private func mobileConnection(_ info: FleetConnectionInfo) -> MobileConnectionState {
        switch info.phase {
        case .idle: return .idle
        case .connecting: return .connecting
        case .connected: return .connected(version: info.version ?? "")
        case .failed: return .failed(info.message ?? String(localized: "Connection failed"))
        }
    }
}
