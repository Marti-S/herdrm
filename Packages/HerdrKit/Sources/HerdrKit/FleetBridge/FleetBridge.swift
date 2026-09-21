import Foundation

/// Stable identity for a workspace inside a multi-device Herdr fleet.
public struct FleetSpaceRef: Codable, Hashable, Sendable, Identifiable {
    public let deviceID: UUID
    public let workspaceID: String

    public init(deviceID: UUID, workspaceID: String) {
        self.deviceID = deviceID
        self.workspaceID = workspaceID
    }

    public var id: Self { self }
}

/// Stable identity for a pane inside a multi-device Herdr fleet.
public struct FleetPaneRef: Codable, Hashable, Sendable, Identifiable {
    public let deviceID: UUID
    public let paneID: String

    public init(deviceID: UUID, paneID: String) {
        self.deviceID = deviceID
        self.paneID = paneID
    }

    public var id: Self { self }
}

/// Stable identity for a tab inside a multi-device Herdr fleet.
public struct FleetTabRef: Codable, Hashable, Sendable, Identifiable {
    public let deviceID: UUID
    public let tabID: String

    public init(deviceID: UUID, tabID: String) {
        self.deviceID = deviceID
        self.tabID = tabID
    }

    public var id: Self { self }
}

/// The non-secret device metadata a Mac host publishes to paired clients.
///
/// SSH usernames, hosts, ports, socket paths, passwords, and private keys stay
/// host-owned and never appear in the bridge snapshot.
public struct FleetDeviceDescriptor: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case local
        case remote
    }

    public let id: UUID
    public let name: String
    public let kind: Kind
    public let osID: String?

    public init(
        id: UUID,
        name: String,
        kind: Kind,
        osID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.osID = osID
    }

    public var isLocal: Bool { kind == .local }
    public var subtitle: String { isLocal ? "This Mac" : "Remote device" }
}

public enum FleetConnectionPhase: String, Codable, Sendable {
    case idle
    case connecting
    case connected
    case failed
}

/// Wire-safe connection state without exposing app-specific enum cases.
public struct FleetConnectionInfo: Codable, Equatable, Sendable {
    public let phase: FleetConnectionPhase
    public let version: String?
    public let message: String?

    public init(
        phase: FleetConnectionPhase,
        version: String? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.version = phase == .connected ? version : nil
        self.message = phase == .failed ? message : nil
    }

    public static let idle = FleetConnectionInfo(phase: .idle)
    public static let connecting = FleetConnectionInfo(phase: .connecting)

    public static func connected(version: String) -> FleetConnectionInfo {
        FleetConnectionInfo(phase: .connected, version: version)
    }

    public static func failed(_ message: String) -> FleetConnectionInfo {
        FleetConnectionInfo(phase: .failed, message: message)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            phase: try container.decode(FleetConnectionPhase.self, forKey: .phase),
            version: try container.decodeIfPresent(String.self, forKey: .version),
            message: try container.decodeIfPresent(String.self, forKey: .message)
        )
    }
}

/// One device as seen by the Mac host at a fleet revision.
public struct FleetDeviceSnapshot: Codable, Identifiable, Equatable, Sendable {
    public let device: FleetDeviceDescriptor
    public let connection: FleetConnectionInfo
    public let snapshot: SessionSnapshot?
    public let availableAgentKinds: [String]

    public var id: UUID { device.id }

    public init(
        device: FleetDeviceDescriptor,
        connection: FleetConnectionInfo,
        snapshot: SessionSnapshot?,
        availableAgentKinds: [String] = []
    ) {
        self.device = device
        self.connection = connection
        self.snapshot = snapshot
        self.availableAgentKinds = availableAgentKinds
    }

    public func agent(paneID: String) -> AgentInfo? {
        snapshot?.agents.first { $0.paneID == paneID }
    }

    public func terminal(paneID: String) -> PaneInfo? {
        snapshot?.ordinaryTerminalPanes.first { $0.paneID == paneID }
    }

    public func workspace(workspaceID: String) -> WorkspaceInfo? {
        snapshot?.workspaces.first { $0.workspaceID == workspaceID }
    }

    public func tab(tabID: String) -> TabInfo? {
        snapshot?.tabs?.first { $0.tabID == tabID }
    }
}

/// Complete host-owned fleet state. Revisions are monotonic for the lifetime
/// of one bridge server process; clients resynchronise with a full snapshot.
public struct FleetSnapshot: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let devices: [FleetDeviceSnapshot]

    public init(revision: UInt64, devices: [FleetDeviceSnapshot]) {
        self.revision = revision
        self.devices = devices
    }

    public func device(_ id: UUID) -> FleetDeviceSnapshot? {
        devices.first { $0.id == id }
    }

    public func agent(_ ref: FleetPaneRef) -> AgentInfo? {
        device(ref.deviceID)?.agent(paneID: ref.paneID)
    }

    public func terminal(_ ref: FleetPaneRef) -> PaneInfo? {
        device(ref.deviceID)?.terminal(paneID: ref.paneID)
    }

    public func workspace(_ ref: FleetSpaceRef) -> WorkspaceInfo? {
        device(ref.deviceID)?.workspace(workspaceID: ref.workspaceID)
    }

    public func tab(_ ref: FleetTabRef) -> TabInfo? {
        device(ref.deviceID)?.tab(tabID: ref.tabID)
    }

    public var agentCount: Int {
        devices.reduce(0) { $0 + ($1.snapshot?.agents.count ?? 0) }
    }

    public var terminalCount: Int {
        devices.reduce(0) { $0 + ($1.snapshot?.ordinaryTerminalPanes.count ?? 0) }
    }
}

/// Codable terminal target used by the bridge protocol.
public struct FleetTerminalTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case agent
        case terminal
    }

    public let kind: Kind
    public let value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    public init(_ target: TerminalAttachTarget) {
        switch target {
        case .agent(let paneID):
            self.init(kind: .agent, value: paneID)
        case .terminal(let terminalID):
            self.init(kind: .terminal, value: terminalID)
        }
    }

    public var attachTarget: TerminalAttachTarget {
        switch kind {
        case .agent: return .agent(paneID: value)
        case .terminal: return .terminal(terminalID: value)
        }
    }
}

/// Public factory used by fleet adapters outside HerdrKit. The normal
/// socket decoder continues to use Codable synthesis.
extension SessionSnapshot {
    public static func fleet(
        agents: [AgentInfo],
        workspaces: [WorkspaceInfo],
        tabs: [TabInfo]? = nil,
        panes: [PaneInfo]? = nil,
        focusedPaneID: String? = nil,
        focusedWorkspaceID: String? = nil,
        version: String? = nil,
        protocolVersion: Int? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            agents: agents,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            focusedPaneID: focusedPaneID,
            focusedWorkspaceID: focusedWorkspaceID,
            version: version,
            protocolVersion: protocolVersion
        )
    }
}
