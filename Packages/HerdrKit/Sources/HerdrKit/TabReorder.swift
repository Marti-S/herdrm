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

        // herdr's `move_tab` reads `insert_index` against the list as it is
        // BEFORE the move — "insert before the tab currently at this index" —
        // and subtracts one itself when the source sits earlier. Indexing the
        // list with the moving tab already removed double-compensated, landing
        // every forward drag one slot short.
        if let before = plan.beforeWorkspaceID {
            let index = orderedIDs.firstIndex(of: before) ?? orderedIDs.count
            return UInt(index)
        }
        return UInt(orderedIDs.count)
    }
}
