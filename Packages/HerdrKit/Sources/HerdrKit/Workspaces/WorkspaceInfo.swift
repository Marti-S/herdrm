import Foundation

/// Agent status buckets reported by herdr snapshots and status events.
public struct WorkspaceInfo: Codable, Sendable, Identifiable, Equatable {
    public let workspaceID: String
    public let number: Int
    public let label: String
    public let focused: Bool?
    public let paneCount: Int?
    public let tabCount: Int?
    public let activeTabID: String?
    public let agentStatusRaw: String?

    public var id: String { workspaceID }
    public var status: AgentStatus { AgentStatus(wire: agentStatusRaw) }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number
        case label
        case focused
        case paneCount = "pane_count"
        case tabCount = "tab_count"
        case activeTabID = "active_tab_id"
        case agentStatusRaw = "agent_status"
    }
}

/// Any pane in the session, agent or bare shell.
