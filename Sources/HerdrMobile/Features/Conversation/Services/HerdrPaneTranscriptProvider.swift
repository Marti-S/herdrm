import Foundation
import HerdrKit
import SwiftUI

private struct PaneReadEnvelope: Decodable {
    let read: TerminalReadResult
}

extension MobileTransport {
    /// Reads a bounded, terminal-derived transcript without changing the
    /// attached application's viewport.
    func readPaneTranscript(
        paneID: String,
        lines: Int = 250,
        source: TerminalReadSource = .recentUnwrapped
    ) async throws -> TerminalReadResult {
        let boundedLines = max(1, min(lines, 250))
        let envelope: PaneReadEnvelope = try await request(
            method: "pane.read",
            params: .object([
                "pane_id": .string(paneID),
                "source": .string(source.rawValue),
                "lines": .number(Double(boundedLines)),
                "format": .string(TerminalReadFormat.text.rawValue),
                "strip_ansi": .bool(true),
            ]),
            as: PaneReadEnvelope.self
        )
        return envelope.read
    }
}

/// Adapts Herdr's current terminal snapshot API to the semantic transcript
/// boundary. The explicit `.terminal` role prevents terminal text from being
/// misrepresented as structured assistant messages.
struct HerdrPaneTranscriptProvider: AgentTranscriptProvider {
    let transport: any MobileTransport
    let paneID: String
    let lineLimit: Int
    let pollInterval: Duration

    init(
        transport: any MobileTransport,
        paneID: String,
        lineLimit: Int = 250,
        pollInterval: Duration = .milliseconds(900)
    ) {
        self.transport = transport
        self.paneID = paneID
        self.lineLimit = max(1, min(lineLimit, 250))
        self.pollInterval = pollInterval
    }

    func snapshot() async throws -> TranscriptSnapshot {
        let read = try await transport.readPaneTranscript(
            paneID: paneID,
            lines: min(lineLimit, 100)
        )
        return Self.makeSnapshot(read, paneID: paneID)
    }

    func updates(
        after sequence: UInt64?
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let transport = transport
        let paneID = paneID
        let lineLimit = lineLimit
        let pollInterval = pollInterval

        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                var lastSequence = sequence
                var lastText: String?
                do {
                    while !Task.isCancelled {
                        let read = try await transport.readPaneTranscript(
                            paneID: paneID,
                            lines: lineLimit
                        )
                        if lastSequence != read.revision || lastText != read.text {
                            lastSequence = read.revision
                            lastText = read.text
                            continuation.yield(
                                .snapshot(Self.makeSnapshot(read, paneID: paneID))
                            )
                        }
                        try await Task.sleep(for: pollInterval)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }


    private static func makeSnapshot(
        _ read: TerminalReadResult,
        paneID: String
    ) -> TranscriptSnapshot {
        let providerID = "herdr-pane:\(paneID)"
        let readableText = readableTerminalText(read.text)
        let items: [ConversationItem]
        if readableText.isEmpty {
            items = []
        } else {
            items = [
                ConversationItem(
                    id: "\(providerID):terminal",
                    sequence: read.revision,
                    role: .terminal,
                    blocks: [.terminalText(readableText)],
                    state: .complete
                )
            ]
        }
        return TranscriptSnapshot(
            providerID: providerID,
            source: .terminalRecentUnwrapped,
            sequence: read.revision,
            items: items,
            isTruncated: read.truncated
        )
    }

    /// Flattens terminal-only framing without inferring message roles. The raw
    /// terminal remains available from the screen's Terminal mode.
    private static func readableTerminalText(_ text: String) -> String {
        let decoration = CharacterSet(charactersIn: "─━═│┃┄┅┈┉╭╮╰╯├┤┬┴┼_")
        let edgeDecoration = CharacterSet(charactersIn: "│┃╭╮╰╯├┤┬┴┼")
        var output: [String] = []
        var previousWasBlank = true

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            while line.last?.isWhitespace == true { line.removeLast() }
            let visible = line.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }
            let decorationCount = visible.reduce(into: 0) { count, scalar in
                if decoration.contains(scalar) { count += 1 }
            }
            if visible.count >= 3, decorationCount * 5 >= visible.count * 4 {
                line = ""
            } else {
                let withoutBorder = line.trimmingCharacters(in: edgeDecoration)
                if withoutBorder != line {
                    line = withoutBorder.trimmingCharacters(in: .whitespaces)
                }
            }

            if line.isEmpty {
                guard !previousWasBlank else { continue }
                previousWasBlank = true
            } else {
                previousWasBlank = false
            }
            output.append(line)
        }

        while output.last?.isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }

}
