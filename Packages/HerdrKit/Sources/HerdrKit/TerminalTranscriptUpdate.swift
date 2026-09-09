import Foundation

/// A UTF-8-boundary-safe replacement, not an append-only approximation. This
/// handles redraws, progress indicators, and the sliding recent-history window.
public struct TerminalTextPatch: Codable, Sendable, Equatable {
    public let prefixBytes: Int
    public let removedBytes: Int
    public let insertedText: String

    public init(from old: String, to new: String) {
        let before = Array(old.utf8)
        let after = Array(new.utf8)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] {
            prefix += 1
        }
        while prefix > 0,
              (prefix < before.count && before[prefix] & 0xC0 == 0x80)
                || (prefix < after.count && after[prefix] & 0xC0 == 0x80) {
            prefix -= 1
        }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] {
            suffix += 1
        }
        while suffix > 0,
              (before[before.count - suffix] & 0xC0 == 0x80)
                || (after[after.count - suffix] & 0xC0 == 0x80) {
            suffix -= 1
        }
        prefixBytes = prefix
        removedBytes = before.count - prefix - suffix
        insertedText = String(decoding: after[prefix..<(after.count - suffix)], as: UTF8.self)
    }

    public func applying(to text: String) throws -> String {
        let bytes = Array(text.utf8)
        guard prefixBytes >= 0, removedBytes >= 0,
              prefixBytes <= bytes.count, removedBytes <= bytes.count - prefixBytes
        else { throw TerminalTranscriptUpdateError.invalidPatch }
        let end = prefixBytes + removedBytes
        guard (prefixBytes == bytes.count || bytes[prefixBytes] & 0xC0 != 0x80),
              (end == bytes.count || bytes[end] & 0xC0 != 0x80)
        else { throw TerminalTranscriptUpdateError.invalidPatch }
        var result = Data(bytes.prefix(prefixBytes))
        result.append(contentsOf: insertedText.utf8)
        result.append(contentsOf: bytes.dropFirst(end))
        guard let value = String(data: result, encoding: .utf8) else {
            throw TerminalTranscriptUpdateError.invalidPatch
        }
        return value
    }
}

public enum TerminalTranscriptUpdateError: Error, Sendable, Equatable {
    case missingSnapshot
    case sequenceGap
    case invalidPatch
}

/// `sequence` belongs to this subscription, not to the terminal daemon's
/// revision counter. Every new connection starts with an authoritative read.
public struct TerminalTranscriptUpdate: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let baseSequence: UInt64?
    public let read: TerminalReadResult?
    public let patch: TerminalTextPatch?
    public let revision: UInt64?
    public let truncated: Bool?

    public init(sequence: UInt64, read: TerminalReadResult) {
        self.sequence = sequence
        self.read = read
        baseSequence = nil
        patch = nil
        revision = nil
        truncated = nil
    }

    public init(
        sequence: UInt64,
        baseSequence: UInt64,
        previous: TerminalReadResult,
        next: TerminalReadResult
    ) {
        let patch = TerminalTextPatch(from: previous.text, to: next.text)
        let sameMetadata = previous.paneID == next.paneID
            && previous.workspaceID == next.workspaceID && previous.tabID == next.tabID
            && previous.source == next.source && previous.format == next.format
        // Small payloads and large redraws are cheaper and simpler as snapshots.
        let useFull = !sameMetadata || patch.insertedText.utf8.count + 192 >= next.text.utf8.count
        self.sequence = sequence
        self.baseSequence = useFull ? nil : baseSequence
        read = useFull ? next : nil
        self.patch = useFull ? nil : patch
        revision = useFull ? nil : next.revision
        truncated = useFull ? nil : next.truncated
    }
}

public struct TerminalTranscriptAccumulator: Sendable {
    public private(set) var sequence: UInt64?
    public private(set) var read: TerminalReadResult?

    public init() {}

    /// Rejects missing bases rather than silently appending duplicated output.
    /// A caller must open a fresh subscription after a sequence gap.
    @discardableResult
    public mutating func apply(_ update: TerminalTranscriptUpdate) throws -> TerminalReadResult {
        if let sequence, update.sequence <= sequence {
            guard let read else { throw TerminalTranscriptUpdateError.missingSnapshot }
            return read
        }
        let next: TerminalReadResult
        if let full = update.read {
            guard update.patch == nil, update.baseSequence == nil else {
                throw TerminalTranscriptUpdateError.invalidPatch
            }
            next = full
        } else {
            guard let read, let sequence else { throw TerminalTranscriptUpdateError.missingSnapshot }
            guard update.baseSequence == sequence, update.sequence == sequence &+ 1 else {
                throw TerminalTranscriptUpdateError.sequenceGap
            }
            guard let patch = update.patch, let revision = update.revision,
                  let truncated = update.truncated
            else { throw TerminalTranscriptUpdateError.invalidPatch }
            next = TerminalReadResult(
                paneID: read.paneID, workspaceID: read.workspaceID, tabID: read.tabID,
                source: read.source, format: read.format,
                text: try patch.applying(to: read.text), revision: revision, truncated: truncated
            )
        }
        read = next
        sequence = update.sequence
        return next
    }
}

public enum FleetBridgePerformanceProtocol {
    public static let capabilitiesMethod = "bridge.capabilities"
    public static let transcriptMethod = "bridge.pane.subscribe"
    public static let pingMethod = "bridge.ping"
    public static let maximumInFlightRequests = 32
}
