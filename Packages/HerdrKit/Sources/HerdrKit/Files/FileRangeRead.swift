import Foundation

/// One bounded byte-range read of a remote or local file, used to tail
/// append-only transcripts (Atomic/Pi session JSONL) without re-downloading
/// the whole file on every poll.
public struct FileRangeRead: Sendable, Equatable {
    /// Bytes from `offset` up to `limit`. Empty when the file has not grown.
    public let data: Data
    /// Total file size at read time. A size smaller than the caller's offset
    /// means the file was truncated or replaced.
    public let totalSize: Int64

    public init(data: Data, totalSize: Int64) {
        self.data = data
        self.totalSize = totalSize
    }

    /// Bytes read per call. Large enough for a busy tool result, small enough
    /// to keep a single SSH exec bounded.
    public static let defaultLimit = 2 * 1024 * 1024

    /// POSIX shell command printing `<size>\n` followed by the raw byte range.
    /// `tail -c +N` is 1-based; `head -c` bounds the range. A negative offset
    /// means "the last `-offset` bytes" (`tail -c N`), so an initial tail
    /// window costs one round trip and never ships the head of a large file.
    /// Missing file → 0 size and no payload.
    public static func shellCommand(path: String, offset: Int64, limit: Int) -> String {
        let quoted = ShellQuoting.quoted(path)
        let range = offset < 0
            ? "tail -c \(-offset) \"$f\" | head -c \(limit)"
            : "tail -c +\(offset + 1) \"$f\" | head -c \(limit)"
        return
            "f=\(quoted); if [ -f \"$f\" ]; then s=$(wc -c < \"$f\" | tr -d ' '); "
            + "printf '%s\\n' \"$s\"; "
            + range + "; "
            + "else printf '0\\n'; fi"
    }

    /// Absolute start offset a read actually began at, given the file size.
    public static func startOffset(offset: Int64, totalSize: Int64) -> Int64 {
        offset < 0 ? max(0, totalSize + offset) : min(offset, totalSize)
    }

    /// Parses the `shellCommand` output.
    public static func parse(_ output: Data) throws -> FileRangeRead {
        guard let newline = output.firstIndex(of: 0x0A) else {
            throw HerdrError.malformedResponse("file range read returned no size line")
        }
        let sizeText = String(decoding: output[output.startIndex..<newline], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard let size = Int64(sizeText) else {
            throw HerdrError.malformedResponse("file range read returned an invalid size")
        }
        return FileRangeRead(data: Data(output[output.index(after: newline)...]), totalSize: size)
    }

    /// Reads the range from a local file.
    public static func readLocal(path: String, offset: Int64, limit: Int) throws -> FileRangeRead {
        guard FileManager.default.fileExists(atPath: path) else {
            return FileRangeRead(data: Data(), totalSize: 0)
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        let start = startOffset(offset: offset, totalSize: size)
        guard start < size else { return FileRangeRead(data: Data(), totalSize: size) }
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.read(upToCount: limit) ?? Data()
        return FileRangeRead(data: data, totalSize: size)
    }

    /// Only agent session transcripts may be tailed through the bridge; the
    /// mobile client never needs arbitrary file access.
    public static func isAllowedSessionPath(_ path: String) -> Bool {
        path.hasSuffix(".jsonl") && !path.contains("..")
            && (path.contains("/.atomic/agent/sessions/") || path.contains("/.pi/agent/sessions/"))
    }
}
