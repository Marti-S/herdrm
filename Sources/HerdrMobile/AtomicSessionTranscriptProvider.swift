import Foundation
import HerdrKit

/// Structured transcript for Atomic / Pi agents, read straight from the
/// session JSONL herdr reports in `agent_session`. Tails the file by byte
/// offset so each poll only transfers what was appended since the last one.
///
/// Cost model: every read is one SSH exec (or one bridge request), so the
/// provider does as few as possible —
/// - the first read asks for the last `initialTailBytes` in a single round
///   trip (negative offset); the head of a large file is never transferred,
/// - `snapshot()` and `updates()` share one cursor, so the update stream
///   continues from the bytes the snapshot already parsed instead of
///   re-downloading the window,
/// - idle polls return only the size line.
struct AtomicSessionTranscriptProvider: AgentTranscriptProvider {
    let transport: any MobileTransport
    let paneID: String
    let sessionPath: String
    let pollInterval: Duration
    let initialTailBytes: Int64

    private let cursor: Cursor

    init(
        transport: any MobileTransport,
        paneID: String,
        sessionPath: String,
        pollInterval: Duration = .milliseconds(1_000),
        initialTailBytes: Int64 = 512 * 1024
    ) {
        self.transport = transport
        self.paneID = paneID
        self.sessionPath = sessionPath
        self.pollInterval = pollInterval
        self.initialTailBytes = initialTailBytes
        self.cursor = Cursor(
            transport: transport,
            path: sessionPath,
            providerID: "atomic-session:\(paneID)",
            initialTailBytes: initialTailBytes
        )
    }

    func snapshot() async throws -> TranscriptSnapshot {
        _ = try await cursor.pull()
        return await cursor.snapshot()
    }

    func updates(after sequence: UInt64?) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let cursor = cursor
        let pollInterval = pollInterval
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    // Resync only if the store is behind the cursor (or the
                    // cursor was never primed); otherwise start polling.
                    let changed = try await cursor.pull()
                    let cursorSequence = await cursor.sequence
                    if changed || sequence != cursorSequence {
                        continuation.yield(.snapshot(await cursor.snapshot()))
                    }
                    while !Task.isCancelled {
                        try await Task.sleep(for: pollInterval)
                        if try await cursor.pull() {
                            continuation.yield(.snapshot(await cursor.snapshot()))
                        }
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

    /// Byte offset into the file plus the parser state. An actor so the
    /// snapshot and the update stream never race on the same file position.
    private actor Cursor {
        private let transport: any MobileTransport
        private let path: String
        private let providerID: String
        private let initialTailBytes: Int64

        private var parser = AtomicSessionTranscriptParser()
        private var offset: Int64 = 0
        private var truncatedHead = false
        private var primed = false

        init(
            transport: any MobileTransport,
            path: String,
            providerID: String,
            initialTailBytes: Int64
        ) {
            self.transport = transport
            self.path = path
            self.providerID = providerID
            self.initialTailBytes = initialTailBytes
        }

        var sequence: UInt64 { parser.sequence }

        /// True while a read is in flight. `SessionDriver` serializes SSH
        /// operations FIFO with an uncancellable wait, so a stalled read must
        /// not make the next caller queue behind it on this actor.
        private var reading = false

        /// Reads everything appended since the cursor. Returns true when the
        /// transcript changed. A concurrent call is skipped once the cursor
        /// holds content; the very first read is never skipped, because its
        /// caller has nothing to display yet.
        func pull() async throws -> Bool {
            guard !(reading && primed) else { return false }
            reading = true
            defer { reading = false }
            var changed = false
            var pass = 0
            while pass < 8 {
                pass += 1
                let requestOffset = primed ? offset : -initialTailBytes
                let read = try await transport.readFileRange(
                    path: path,
                    offset: requestOffset,
                    limit: FileRangeRead.defaultLimit
                )
                if primed, read.totalSize < offset {
                    // Truncated or replaced: start over from the tail window.
                    parser.reset()
                    primed = false
                    truncatedHead = false
                    changed = true
                    continue
                }
                let start = FileRangeRead.startOffset(offset: requestOffset, totalSize: read.totalSize)
                var data = read.data
                if !primed {
                    primed = true
                    offset = start
                    truncatedHead = start > 0
                    if truncatedHead {
                        // Resync at the first full line of the tail window.
                        if let newline = data.firstIndex(of: 0x0A) {
                            data = Data(data[data.index(after: newline)...])
                        } else {
                            data = Data()
                        }
                    }
                }
                guard !read.data.isEmpty else { break }
                parser.append(data)
                offset += Int64(read.data.count)
                changed = true
                if read.data.count < FileRangeRead.defaultLimit { break }
            }
            return changed
        }

        func snapshot() -> TranscriptSnapshot {
            var items = parser.items
            // A trailing assistant turn with unanswered tool calls is live.
            if parser.hasRunningTools, let last = items.indices.last,
               items[last].role == .assistant {
                items[last].state = .streaming
            }
            return TranscriptSnapshot(
                providerID: providerID,
                source: .semantic,
                sequence: parser.sequence,
                items: items,
                isTruncated: truncatedHead
            )
        }
    }
}
