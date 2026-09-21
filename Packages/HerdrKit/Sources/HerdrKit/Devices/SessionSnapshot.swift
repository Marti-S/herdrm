import Foundation

/// Agent status buckets reported by herdr snapshots and status events.
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public let agents: [AgentInfo]
    public let workspaces: [WorkspaceInfo]
    public let tabs: [TabInfo]?
    public let panes: [PaneInfo]?
    public let focusedPaneID: String?
    public let focusedWorkspaceID: String?
    public let version: String?
    public let protocolVersion: Int?

    /// Server-owned panes that are attachable as ordinary terminals. Agent panes
    /// are excluded by the authoritative agent list so the UI never shows one in
    /// both sections while detection metadata is changing.
    public var ordinaryTerminalPanes: [PaneInfo] {
        let agentPaneIDs = Set(agents.map(\.paneID))
        return (panes ?? []).filter {
            $0.terminalID != nil && !agentPaneIDs.contains($0.paneID)
        }
    }

    public func updatingAgentStatus(paneID: String, status: AgentStatus) -> SessionSnapshot? {
        var agents = agents
        guard let index = agents.firstIndex(where: { $0.paneID == paneID }) else {
            return nil
        }
        agents[index] = agents[index].updatingStatus(status)
        return SessionSnapshot(
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

    enum CodingKeys: String, CodingKey {
        case agents
        case workspaces
        case tabs
        case panes
        case focusedPaneID = "focused_pane_id"
        case focusedWorkspaceID = "focused_workspace_id"
        case version
        case protocolVersion = "protocol"
    }
}
