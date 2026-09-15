import Foundation

/// Incremental parser for Atomic / Pi session JSONL
/// (`~/.atomic/agent/sessions/…/<ts>_<uuid>.jsonl`, session-format v2/v3).
///
/// Feed it raw bytes as the file grows; it keeps the trailing partial line
/// and turns `message` entries into `ConversationItem`s:
///
/// - `user`         → one `.user` item with the prompt as markdown
/// - `assistant`    → one `.assistant` item: text → `.markdown`,
///                    `toolCall` → `.tool(running)`, thinking dropped
/// - `toolResult`   → flips the matching tool block to succeeded/failed and
///                    attaches a bounded output preview as detail
/// - `bashExecution`→ one `.tool` item for a `!` shell command
/// - `custom`       → `.notice` when `display` is true
///
/// Everything else (model changes, compaction, branch summaries) is skipped.
/// Entries form a tree via `parentId`; this reader presents them in file
/// order, which is what the TUI shows for a live session.
public struct AtomicSessionTranscriptParser: Sendable {
    public private(set) var items: [ConversationItem] = []
    /// Monotonic line counter, used as the transcript sequence.
    public private(set) var sequence: UInt64 = 0
    public private(set) var sessionCwd: String?

    private var pendingLine = Data()
    /// toolCallId → (item index, block index) awaiting a `toolResult`.
    private var openToolCalls: [String: (item: Int, block: Int)] = [:]

    public static let toolOutputPreviewLimit = 1_200
    public static let toolArgumentSummaryLimit = 120

    public init() {}

    /// True while any tool call is still waiting for its result.
    public var hasRunningTools: Bool { !openToolCalls.isEmpty }

    /// Appends newly read bytes. Complete lines are parsed; a trailing partial
    /// line waits for the next chunk.
    public mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var buffer = pendingLine
        buffer.append(chunk)
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            if !line.isEmpty { parseLine(Data(line)) }
            start = buffer.index(after: newline)
        }
        pendingLine = Data(buffer[start...])
    }

    /// Restarts from an empty file (the session was truncated or replaced).
    public mutating func reset() {
        self = AtomicSessionTranscriptParser()
    }

    // MARK: - Entry parsing

    private mutating func parseLine(_ line: Data) {
        sequence += 1
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return }
        switch type {
        case "session":
            sessionCwd = object["cwd"] as? String
        case "message":
            guard let message = object["message"] as? [String: Any],
                  let role = message["role"] as? String
            else { return }
            let entryID = (object["id"] as? String) ?? String(sequence)
            parseMessage(message, role: role, entryID: entryID)
        default:
            return
        }
    }

    private mutating func parseMessage(_ message: [String: Any], role: String, entryID: String) {
        switch role {
        case "user":
            let text = Self.plainText(message["content"])
            guard !text.isEmpty else { return }
            items.append(
                ConversationItem(
                    id: entryID, sequence: sequence, role: .user,
                    blocks: [.markdown(text)], state: .complete
                )
            )

        case "assistant":
            var blocks: [TranscriptContentBlock] = []
            var toolBlocks: [(id: String, index: Int)] = []
            for part in (message["content"] as? [[String: Any]]) ?? [] {
                switch part["type"] as? String {
                case "text":
                    let text = ((part["text"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { blocks.append(.markdown(text)) }
                case "toolCall":
                    let name = (part["name"] as? String) ?? "tool"
                    let summary = Self.argumentSummary(
                        tool: name, arguments: part["arguments"] as? [String: Any]
                    )
                    if let callID = part["id"] as? String {
                        toolBlocks.append((callID, blocks.count))
                    }
                    blocks.append(.tool(name: name, status: .running, detail: summary))
                default:
                    continue  // thinking, images
                }
            }
            let stopReason = message["stopReason"] as? String
            if let errorMessage = message["errorMessage"] as? String, !errorMessage.isEmpty {
                blocks.append(.notice(errorMessage))
            }
            guard !blocks.isEmpty else { return }
            let state: ConversationItemState =
                stopReason == "error" || stopReason == "aborted" ? .failed : .complete
            items.append(
                ConversationItem(
                    id: entryID, sequence: sequence, role: .assistant,
                    blocks: blocks, state: state
                )
            )
            let itemIndex = items.count - 1
            for (callID, blockIndex) in toolBlocks {
                openToolCalls[callID] = (itemIndex, blockIndex)
            }

        case "toolResult":
            guard let callID = message["toolCallId"] as? String,
                  let location = openToolCalls.removeValue(forKey: callID),
                  items.indices.contains(location.item),
                  items[location.item].blocks.indices.contains(location.block),
                  case .tool(let name, _, let summary) = items[location.item].blocks[location.block]
            else { return }
            let isError = (message["isError"] as? Bool) ?? false
            let output = Self.plainText(message["content"])
            items[location.item].blocks[location.block] = .tool(
                name: name,
                status: isError ? .failed : .succeeded,
                detail: Self.toolDetail(summary: summary, output: output)
            )

        case "bashExecution":
            let command = (message["command"] as? String) ?? ""
            guard !command.isEmpty else { return }
            let exitCode = message["exitCode"] as? Int
            let cancelled = (message["cancelled"] as? Bool) ?? false
            let output = (message["output"] as? String) ?? ""
            let failed = cancelled || (exitCode != nil && exitCode != 0)
            items.append(
                ConversationItem(
                    id: entryID, sequence: sequence, role: .tool,
                    blocks: [
                        .tool(
                            name: "bash",
                            status: failed ? .failed : .succeeded,
                            detail: Self.toolDetail(summary: command, output: output)
                        )
                    ],
                    state: .complete
                )
            )

        case "custom":
            guard (message["display"] as? Bool) == true else { return }
            let text = Self.plainText(message["content"])
            guard !text.isEmpty else { return }
            items.append(
                ConversationItem(
                    id: entryID, sequence: sequence, role: .system,
                    blocks: [.notice(text)], state: .complete
                )
            )

        default:
            return
        }
    }

    // MARK: - Helpers

    /// Joins text parts of a `string | ContentBlock[]` payload.
    static func plainText(_ content: Any?) -> String {
        if let text = content as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts
            .compactMap { part -> String? in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One-line object for the tool verb: the command for bash, the path for
    /// file tools, the pattern for search, else the first string argument.
    static func argumentSummary(tool: String, arguments: [String: Any]?) -> String? {
        guard let arguments, !arguments.isEmpty else { return nil }
        let preferredKeys: [String]
        switch tool.lowercased() {
        case "bash", "shell", "terminal":
            preferredKeys = ["command", "cmd"]
        case "read", "write", "edit", "cat", "patch":
            preferredKeys = ["path", "file_path", "filePath", "file"]
        case "search", "grep", "code_search", "web_search":
            preferredKeys = ["pattern", "query", "queries"]
        case "find", "glob":
            preferredKeys = ["paths", "pattern", "path"]
        case "fetch_content", "web_fetch":
            preferredKeys = ["url", "urls"]
        default:
            preferredKeys = ["task", "description", "path", "query", "command", "url", "prompt"]
        }
        for key in preferredKeys {
            if let value = scalarSummary(arguments[key]) { return clip(value) }
        }
        for key in arguments.keys.sorted() {
            if let value = scalarSummary(arguments[key]) { return clip(value) }
        }
        return nil
    }

    private static func scalarSummary(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let line = string.split(separator: "\n", omittingEmptySubsequences: true).first
                .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            return line.isEmpty ? nil : line
        case let number as NSNumber:
            return number.stringValue
        case let list as [Any]:
            let parts = list.compactMap { scalarSummary($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default:
            return nil
        }
    }

    private static func clip(_ text: String) -> String {
        guard text.count > toolArgumentSummaryLimit else { return text }
        return String(text.prefix(toolArgumentSummaryLimit - 1)) + "…"
    }

    /// First line is the call summary (what the collapsed row shows); the rest
    /// is a bounded output preview revealed on expand.
    static func toolDetail(summary: String?, output: String) -> String? {
        let head = summary ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return head.isEmpty ? nil : head }
        let preview: String
        if trimmed.count > toolOutputPreviewLimit {
            preview = String(trimmed.prefix(toolOutputPreviewLimit)) + "\n…"
        } else {
            preview = trimmed
        }
        return head.isEmpty ? preview : head + "\n" + preview
    }
}
