import Foundation

/// Agent status buckets reported by herdr snapshots and status events.
public struct TabInfo: Codable, Sendable, Identifiable, Equatable {
    public let tabID: String
    public let workspaceID: String
    public let number: Int?
    public let label: String
    public let focused: Bool?
    public let paneCount: Int?
    public let agentStatusRaw: String?

    public var id: String { tabID }

    /// herdr labels fresh tabs with their number ("1", "2"); only a label
    /// someone actually set is a display name.
    ///
    /// After `tab.move`, `number` and `label` can desync (`number=1`,
    /// `label="2"`). Any all-digit label is still a default, not a name.
    public var customLabel: String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isNumber) { return nil }
        return trimmed
    }

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case number
        case label
        case focused
        case paneCount = "pane_count"
        case agentStatusRaw = "agent_status"
    }
}
