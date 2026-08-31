import Foundation

/// Stable identity for a workspace inside a multi-device Herdr fleet.
public struct FleetSpaceRef: Codable, Hashable, Sendable {
    public let deviceID: UUID
    public let workspaceID: String

    public init(deviceID: UUID, workspaceID: String) {
        self.deviceID = deviceID
        self.workspaceID = workspaceID
    }
}

/// Stable identity for a pane inside a multi-device Herdr fleet.
public struct FleetPaneRef: Codable, Hashable, Sendable {
    public let deviceID: UUID
    public let paneID: String

    public init(deviceID: UUID, paneID: String) {
        self.deviceID = deviceID
        self.paneID = paneID
    }
}

/// The non-secret device metadata a Mac host publishes to paired clients.
public struct FleetDeviceDescriptor: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let subtitle: String
    public let isLocal: Bool
    public let osID: String?

    public init(
        id: UUID,
        name: String,
        subtitle: String,
        isLocal: Bool,
        osID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.isLocal = isLocal
        self.osID = osID
    }
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
        self.version = version
        self.message = message
    }

    public static let idle = FleetConnectionInfo(phase: .idle)
    public static let connecting = FleetConnectionInfo(phase: .connecting)

    public static func connected(version: String) -> FleetConnectionInfo {
        FleetConnectionInfo(phase: .connected, version: version)
    }

    public static func failed(_ message: String) -> FleetConnectionInfo {
        FleetConnectionInfo(phase: .failed, message: message)
    }
}

/// One device as seen by the Mac host at a fleet revision.
public struct FleetDeviceSnapshot: Codable, Identifiable, Equatable, Sendable {
    public let device: FleetDeviceDescriptor
    public let connection: FleetConnectionInfo
    public let snapshot: SessionSnapshot?

    public var id: UUID { device.id }

    public init(
        device: FleetDeviceDescriptor,
        connection: FleetConnectionInfo,
        snapshot: SessionSnapshot?
    ) {
        self.device = device
        self.connection = connection
        self.snapshot = snapshot
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
