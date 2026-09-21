import Foundation

/// The role of one semantic conversation item.
///
/// `terminal` is intentionally distinct from `assistant`: terminal-derived
/// snapshots do not contain reliable message roles and must not be presented as
/// if they did.
public enum ConversationRole: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case assistant
    case tool
    case system
    case terminal
}

public enum ConversationItemState: String, Codable, Sendable, Equatable {
    case streaming
    case complete
    case failed
}

public enum TranscriptToolStatus: String, Codable, Sendable, Equatable {
    case pending
    case running
    case succeeded
    case failed
}

/// One independently renderable block inside a conversation item.
public enum TranscriptContentBlock: Codable, Sendable, Equatable {
    case markdown(String)
    case code(language: String?, text: String)
    case tool(name: String, status: TranscriptToolStatus, detail: String?)
    case notice(String)
    case terminalText(String)
}

/// A stable semantic row in a conversation transcript.
public struct ConversationItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sequence: UInt64
    public let role: ConversationRole
    public var blocks: [TranscriptContentBlock]
    public var state: ConversationItemState

    public init(
        id: String,
        sequence: UInt64,
        role: ConversationRole,
        blocks: [TranscriptContentBlock],
        state: ConversationItemState
    ) {
        self.id = id
        self.sequence = sequence
        self.role = role
        self.blocks = blocks
        self.state = state
    }
}

/// Describes how much semantic information backs a transcript.
public enum TranscriptSource: String, Codable, Sendable, Equatable {
    case semantic
    case terminalRecentUnwrapped = "terminal_recent_unwrapped"
    case terminalVisible = "terminal_visible"
}

/// A complete, ordered transcript snapshot.
public struct TranscriptSnapshot: Codable, Sendable, Equatable {
    public let providerID: String
    public let source: TranscriptSource
    public let sequence: UInt64
    public let items: [ConversationItem]
    public let isTruncated: Bool
    public let capturedAt: Date

    public init(
        providerID: String,
        source: TranscriptSource,
        sequence: UInt64,
        items: [ConversationItem],
        isTruncated: Bool = false,
        capturedAt: Date = Date()
    ) {
        self.providerID = providerID
        self.source = source
        self.sequence = sequence
        self.items = items
        self.isTruncated = isTruncated
        self.capturedAt = capturedAt
    }

    public static func empty(
        providerID: String,
        source: TranscriptSource = .semantic
    ) -> TranscriptSnapshot {
        TranscriptSnapshot(
            providerID: providerID,
            source: source,
            sequence: 0,
            items: []
        )
    }
}

/// Incremental events emitted by a semantic transcript provider.
public enum TranscriptEvent: Sendable, Equatable {
    case snapshot(TranscriptSnapshot)
    case itemStarted(ConversationItem)
    case blockDelta(sequence: UInt64, itemID: String, blockIndex: Int, text: String)
    case itemCompleted(sequence: UInt64, itemID: String)
    case toolUpdated(
        sequence: UInt64,
        itemID: String,
        blockIndex: Int,
        status: TranscriptToolStatus,
        detail: String?
    )

    public var sequence: UInt64 {
        switch self {
        case .snapshot(let snapshot):
            return snapshot.sequence
        case .itemStarted(let item):
            return item.sequence
        case .blockDelta(let sequence, _, _, _),
             .itemCompleted(let sequence, _),
             .toolUpdated(let sequence, _, _, _, _):
            return sequence
        }
    }
}

/// A transport-independent source of stable conversation items.
///
/// Current Herdr servers are adapted through terminal snapshots. A future
/// semantic Herdr endpoint can implement this same protocol without changing
/// the reader UI or its scroll behavior.
public protocol AgentTranscriptProvider: Sendable {
    func snapshot() async throws -> TranscriptSnapshot

    func updates(
        after sequence: UInt64?
    ) -> AsyncThrowingStream<TranscriptEvent, Error>
}

public extension TranscriptSnapshot {
    /// Applies one incremental provider event while preserving stable row IDs.
    func applying(_ event: TranscriptEvent) -> TranscriptSnapshot {
        switch event {
        case .snapshot(let snapshot):
            return snapshot

        case .itemStarted(let item):
            var nextItems = items
            if let index = nextItems.firstIndex(where: { $0.id == item.id }) {
                nextItems[index] = item
            } else {
                nextItems.append(item)
            }
            return replacing(
                sequence: max(sequence, item.sequence),
                items: nextItems
            )

        case .blockDelta(let eventSequence, let itemID, let blockIndex, let text):
            guard !text.isEmpty,
                  let itemIndex = items.firstIndex(where: { $0.id == itemID }),
                  items[itemIndex].blocks.indices.contains(blockIndex)
            else { return self }

            var nextItems = items
            nextItems[itemIndex].blocks[blockIndex] =
                nextItems[itemIndex].blocks[blockIndex].appending(text)
            nextItems[itemIndex].state = .streaming
            return replacing(
                sequence: max(sequence, eventSequence),
                items: nextItems
            )

        case .itemCompleted(let eventSequence, let itemID):
            guard let itemIndex = items.firstIndex(where: { $0.id == itemID }) else {
                return self
            }
            var nextItems = items
            nextItems[itemIndex].state = .complete
            return replacing(
                sequence: max(sequence, eventSequence),
                items: nextItems
            )

        case .toolUpdated(
            let eventSequence,
            let itemID,
            let blockIndex,
            let status,
            let detail
        ):
            guard let itemIndex = items.firstIndex(where: { $0.id == itemID }),
                  items[itemIndex].blocks.indices.contains(blockIndex),
                  case .tool(let name, _, _) = items[itemIndex].blocks[blockIndex]
            else { return self }

            var nextItems = items
            nextItems[itemIndex].blocks[blockIndex] = .tool(
                name: name,
                status: status,
                detail: detail
            )
            return replacing(
                sequence: max(sequence, eventSequence),
                items: nextItems
            )
        }
    }

    private func replacing(
        sequence: UInt64,
        items: [ConversationItem]
    ) -> TranscriptSnapshot {
        TranscriptSnapshot(
            providerID: providerID,
            source: source,
            sequence: sequence,
            items: items,
            isTruncated: isTruncated,
            capturedAt: Date()
        )
    }
}

private extension TranscriptContentBlock {
    func appending(_ suffix: String) -> TranscriptContentBlock {
        switch self {
        case .markdown(let text):
            return .markdown(text + suffix)
        case .code(let language, let text):
            return .code(language: language, text: text + suffix)
        case .tool(let name, let status, let detail):
            let nextDetail = (detail ?? "") + suffix
            return .tool(
                name: name,
                status: status,
                detail: nextDetail.isEmpty ? nil : nextDetail
            )
        case .notice(let text):
            return .notice(text + suffix)
        case .terminalText(let text):
            return .terminalText(text + suffix)
        }
    }
}

/// Sources accepted by Herdr's `pane.read` operation.
public enum TerminalReadSource: String, Codable, Sendable, Equatable {
    case visible
    case recent
    case recentUnwrapped = "recent_unwrapped"
    case detection
}

public enum TerminalReadFormat: String, Codable, Sendable, Equatable {
    case text
    case ansi
}

/// The typed `result.read` payload returned by Herdr's `pane.read` operation.
public struct TerminalReadResult: Codable, Sendable, Equatable {
    public let paneID: String
    public let workspaceID: String
    public let tabID: String
    public let source: TerminalReadSource
    public let format: TerminalReadFormat
    public let text: String
    public let revision: UInt64
    public let truncated: Bool

    public init(
        paneID: String,
        workspaceID: String,
        tabID: String,
        source: TerminalReadSource,
        format: TerminalReadFormat,
        text: String,
        revision: UInt64,
        truncated: Bool
    ) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.source = source
        self.format = format
        self.text = text
        self.revision = revision
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case source
        case format
        case text
        case revision
        case truncated
    }
}
