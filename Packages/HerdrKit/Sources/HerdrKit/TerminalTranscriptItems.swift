import Foundation

public enum TerminalTranscriptItems {
    /// Small stable rows make a growing terminal transcript independently
    /// renderable. IDs include the bounded chunk contents and occurrence, so
    /// duplicate text remains valid and unchanged rows keep their identity.
    public static func make(
        text: String, providerID: String, maximumLinesPerItem: Int = 12
    ) -> [ConversationItem] {
        guard !text.isEmpty else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let limit = max(1, maximumLinesPerItem)
        var occurrences: [String: Int] = [:]
        return stride(from: 0, to: lines.count, by: limit).map { start in
            let chunk = lines[start..<min(start + limit, lines.count)].joined(separator: "\n")
            let occurrence = occurrences[chunk, default: 0]
            occurrences[chunk] = occurrence + 1
            return ConversationItem(
                id: "\(providerID):terminal:\(chunk.utf8.count):\(chunk):\(occurrence)",
                // The containing snapshot owns the terminal revision. Changing
                // only that revision must not invalidate every unchanged row.
                sequence: 0, role: .terminal, blocks: [.terminalText(chunk)], state: .complete
            )
        }
    }
}
