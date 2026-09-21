import Foundation

/// Agent status buckets reported by herdr snapshots and status events.
public enum TerminalAttachTarget: Sendable, Equatable {
    case agent(paneID: String)
    case terminal(terminalID: String)
}
