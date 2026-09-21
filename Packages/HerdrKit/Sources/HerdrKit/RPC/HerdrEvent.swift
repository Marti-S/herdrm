import Foundation

/// Agent status buckets reported by herdr snapshots and status events.
public struct HerdrEvent: Sendable {
    public let kind: String
    public let payload: JSONValue

    public init(kind: String, payload: JSONValue) {
        self.kind = kind
        self.payload = payload
    }

    public static let subscriptionStartedKind = "subscription.started"
    public static let agentStatusChangedKind = "pane.agent_status_changed"

    /// All parameterless (globally subscribable) lifecycle kinds.
    /// `pane.agent_status_changed` is pane-scoped and appended separately for
    /// each known pane by `SocketRPC.events`.
    public static let allKinds: [String] = [
        "workspace.created", "workspace.updated", "workspace.metadata_updated", "workspace.renamed",
        "workspace.moved", "workspace.reordered", "workspace.focused", "workspace.closed",
        "worktree.created", "worktree.opened", "worktree.removed",
        "tab.created", "tab.renamed", "tab.moved", "tab.focused", "tab.closed",
        "pane.created", "pane.updated", "pane.moved", "pane.focused", "pane.closed", "pane.exited",
        "pane.agent_detected",
        "layout.updated",
    ]

    private static let scopedKinds = [
        agentStatusChangedKind,
        "pane.scroll_changed",
        "pane.output_matched",
    ]

    private static let normalizedKinds = Dictionary(
        (allKinds + scopedKinds).map {
            ($0.replacingOccurrences(of: ".", with: "_"), $0)
        },
        uniquingKeysWith: { first, _ in first }
    )

    static func normalizedKind(_ wireKind: String) -> String {
        normalizedKinds[wireKind] ?? wireKind
    }
}
