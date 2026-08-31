import Foundation

/// Global pane identity. Herdr pane ids are only unique inside one device.
public struct FleetPaneRef: Codable, Hashable, Sendable, Identifiable {
    public let deviceID: UUID
    public let paneID: String

    public init(deviceID: UUID, paneID: String) {
        self.deviceID = deviceID
        self.paneID = paneID
    }

    public var id: Self { self }
}

/// Global workspace identity. Herdr workspace ids are only unique inside one device.
public struct FleetSpaceRef: Codable, Hashable, Sendable, Identifiable {
    public let deviceID: UUID
    public let workspaceID: String

    public init(deviceID: UUID, workspaceID: String) {
        self.deviceID = deviceID
        self.workspaceID = workspaceID
    }

    public var id: Self { self }
}

/// Global tab identity. Herdr tab ids are only unique inside one device.
public struct FleetTabRef: Codable, Hashable, Sendable, Identifiable {
    public let deviceID: UUID
    public let tabID: String

    public init(deviceID: UUID, tabID: String) {
        self.deviceID = deviceID
        self.tabID = tabID
    }

    public var id: Self { self }
}

/// Sanitized device metadata safe to send to paired clients.
///
/// SSH targets, passwords, private keys, and socket paths deliberately remain
/// host-owned and never appear in the fleet protocol.
public struct FleetDeviceInfo: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case local
        case remote
    }

    public let id: UUID
    public let name: String
    public let kind: Kind
    public let osID: String?

    public init(id: UUID, name: String, kind: Kind, osID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.osID = osID
    }

    public init(device: Device) {
        self.init(
            id: device.id,
            name: device.name,
            kind: device.isLocal ? .local : .remote,
            osID: device.osID
        )
    }

    public var isLocal: Bool { kind == .local }
}

/// Stable connection state sent by the Mac host to clients.
public struct FleetConnectionState: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case idle
        case connecting
        case connected
        case failed
    }

    public let phase: Phase
    public let version: String?
    public let message: String?

    public init(
        phase: Phase,
        version: String? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        switch phase {
        case .idle, .connecting:
            self.version = nil
            self.message = nil
        case .connected:
            self.version = version
            self.message = nil
        case .failed:
            self.version = nil
            self.message = message
        }
    }

    public static let idle = FleetConnectionState(phase: .idle)
    public static let connecting = FleetConnectionState(phase: .connecting)

    public static func connected(version: String) -> FleetConnectionState {
        FleetConnectionState(phase: .connected, version: version)
    }

    public static func failed(_ message: String) -> FleetConnectionState {
        FleetConnectionState(phase: .failed, message: message)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            phase: try container.decode(Phase.self, forKey: .phase),
            version: try container.decodeIfPresent(String.self, forKey: .version),
            message: try container.decodeIfPresent(String.self, forKey: .message)
        )
    }
}

/// One host-owned Herdr device projected into the shared fleet.
///
/// `terminals` contains ordinary attachable terminal panes only. Agent panes
/// remain in `agents`, preventing one pane from appearing twice in clients.
public struct FleetDeviceSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let device: FleetDeviceInfo
    public let connection: FleetConnectionState
    public let agents: [AgentInfo]
    public let workspaces: [WorkspaceInfo]
    public let tabs: [TabInfo]
    public let terminals: [PaneInfo]
    public let availableAgentKinds: [String]

    public init(
        device: FleetDeviceInfo,
        connection: FleetConnectionState,
        agents: [AgentInfo] = [],
        workspaces: [WorkspaceInfo] = [],
        tabs: [TabInfo] = [],
        terminals: [PaneInfo] = [],
        availableAgentKinds: [String] = []
    ) {
        self.device = device
        self.connection = connection
        self.agents = agents
        self.workspaces = workspaces
        self.tabs = tabs
        self.terminals = terminals
        self.availableAgentKinds = availableAgentKinds
    }

    public var id: UUID { device.id }

    public func agent(paneID: String) -> AgentInfo? {
        agents.first { $0.paneID == paneID }
    }

    public func terminal(paneID: String) -> PaneInfo? {
        terminals.first { $0.paneID == paneID }
    }

    public func workspace(workspaceID: String) -> WorkspaceInfo? {
        workspaces.first { $0.workspaceID == workspaceID }
    }

    public func tab(tabID: String) -> TabInfo? {
        tabs.first { $0.tabID == tabID }
    }
}

/// Complete fleet state at one monotonically increasing host revision.
public struct FleetSnapshot: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let devices: [FleetDeviceSnapshot]

    public init(revision: UInt64, devices: [FleetDeviceSnapshot]) {
        self.revision = revision
        self.devices = devices
    }

    public func device(id: UUID) -> FleetDeviceSnapshot? {
        devices.first { $0.device.id == id }
    }

    public func agent(_ ref: FleetPaneRef) -> AgentInfo? {
        device(id: ref.deviceID)?.agent(paneID: ref.paneID)
    }

    public func terminal(_ ref: FleetPaneRef) -> PaneInfo? {
        device(id: ref.deviceID)?.terminal(paneID: ref.paneID)
    }

    public func workspace(_ ref: FleetSpaceRef) -> WorkspaceInfo? {
        device(id: ref.deviceID)?.workspace(workspaceID: ref.workspaceID)
    }

    public func tab(_ ref: FleetTabRef) -> TabInfo? {
        device(id: ref.deviceID)?.tab(tabID: ref.tabID)
    }

    public var agentCount: Int {
        devices.reduce(0) { $0 + $1.agents.count }
    }

    public var terminalCount: Int {
        devices.reduce(0) { $0 + $1.terminals.count }
    }
}
