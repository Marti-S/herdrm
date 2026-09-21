import Foundation

/// Agent status buckets reported by herdr snapshots and status events.
public struct PaneInfo: Codable, Sendable, Identifiable, Equatable {
    public let paneID: String
    public let terminalID: String?
    public let workspaceID: String
    public let tabID: String?
    public let agentKindRaw: String?
    public let agentStatusRaw: String?
    public let terminalTitle: String?
    public let cwd: String?
    public let revision: Int?

    public var id: String { paneID }
    public var hasAgent: Bool { agentKindRaw != nil }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case terminalID = "terminal_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case agentKindRaw = "agent"
        case agentStatusRaw = "agent_status"
        case terminalTitle = "terminal_title"
        case cwd
        case revision
    }
}

/// A tab in a workspace. Snapshot tabs provide the user-facing label for panes
/// whose terminal application has not published an OSC title.
