import Foundation

/// Maps a sidebar agent drop onto herdr's `tab.move` `insert_index`.
///
/// `orderedIDs` is one workspace's tabs in display order (`number`). The drop
/// target is another tab in that list. Returns `nil` when the drop would not
/// change order (same row, already adjacent, unknown ids).
public enum TabReorder: Sendable {
    public static func insertIndex(
        moving: String,
        onto: String,
        placeAfter: Bool,
        orderedIDs: [String]
    ) -> UInt? {
        guard let plan = WorkspaceReorder.plan(
            moving: moving,
            onto: onto,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return nil }

        let remaining = orderedIDs.filter { $0 != moving }
        if let before = plan.beforeWorkspaceID {
            let index = remaining.firstIndex(of: before) ?? remaining.count
            return UInt(index)
        }
        return UInt(remaining.count)
    }
}
