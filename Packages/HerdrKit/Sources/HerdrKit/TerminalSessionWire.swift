import Foundation

/// Records emitted by `herdr terminal session observe/control`.
public enum TerminalSessionRecord: Sendable, Equatable {
    case frame(TerminalFrame)
    case closed(reason: String?)
}

public enum TerminalSessionWireError: Error, LocalizedError, Sendable, Equatable {
    case emptyRecord
    case invalidRecord(String)
    case unsupportedRecordType(String)
    case recordTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyRecord:
            return "The terminal session emitted an empty record."
        case .invalidRecord(let detail):
            return "The terminal session emitted an invalid record: \(detail)"
        case .unsupportedRecordType(let type):
            return "The terminal session emitted unsupported record type \(type)."
        case .recordTooLarge(let limit):
            return "The terminal session record exceeded \(limit) bytes."
        }
    }
}

/// Codable helpers for Herdr's newline-delimited terminal-session protocol.
public enum TerminalSessionWire {
    public static func decodeRecord(_ data: Data) throws -> TerminalSessionRecord {
        let line = trimLineEnding(data)
        guard !line.isEmpty else { throw TerminalSessionWireError.emptyRecord }

        let decoder = JSONDecoder()
        let type: RecordType
        do {
            type = try decoder.decode(RecordType.self, from: line)
        } catch {
            throw TerminalSessionWireError.invalidRecord(error.localizedDescription)
        }

        switch type.type {
        case "terminal.frame":
            do {
                let envelope = try decoder.decode(FrameEnvelope.self, from: line)
                let frame = TerminalFrame(
                    sequence: envelope.sequence,
                    encoding: envelope.encoding,
                    width: envelope.width,
                    height: envelope.height,
                    isFull: envelope.isFull,
                    bytes: envelope.bytes
                )
                guard frame.size.isValid else { throw TerminalSessionError.invalidSize }
                return .frame(frame)
            } catch let error as TerminalSessionError {
                throw error
            } catch {
                throw TerminalSessionWireError.invalidRecord(error.localizedDescription)
            }
        case "terminal.closed":
            do {
                let envelope = try decoder.decode(ClosedEnvelope.self, from: line)
                return .closed(reason: envelope.reason)
            } catch {
                throw TerminalSessionWireError.invalidRecord(error.localizedDescription)
            }
        default:
            throw TerminalSessionWireError.unsupportedRecordType(type.type)
        }
    }

    public static func encodeInput(_ data: Data) throws -> Data {
        try line(InputCommand(type: "terminal.input", bytes: data))
    }

    public static func encodeResize(_ size: TerminalSize) throws -> Data {
        guard size.isValid else { throw TerminalSessionError.invalidSize }
        return try line(
            ResizeCommand(
                type: "terminal.resize",
                columns: size.columns,
                rows: size.rows,
                cellWidthPixels: size.cellWidthPixels,
                cellHeightPixels: size.cellHeightPixels
            )
        )
    }

    public static func encodeRelease() throws -> Data {
        try line(ReleaseCommand(type: "terminal.release"))
    }

    private static func line<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value) + Data([0x0A])
    }

    private static func trimLineEnding(_ data: Data) -> Data {
        var line = data
        if line.last == 0x0A { line.removeLast() }
        if line.last == 0x0D { line.removeLast() }
        return line
    }

    private struct RecordType: Decodable {
        let type: String
    }

    private struct FrameEnvelope: Decodable {
        let sequence: UInt64
        let encoding: TerminalFrameEncoding
        let width: Int
        let height: Int
        let isFull: Bool
        let bytes: Data

        enum CodingKeys: String, CodingKey {
            case sequence = "seq"
            case encoding
            case width
            case height
            case isFull = "full"
            case bytes
        }
    }

    private struct ClosedEnvelope: Decodable {
        let reason: String?
    }

    private struct InputCommand: Encodable {
        let type: String
        let bytes: Data
    }

    private struct ResizeCommand: Encodable {
        let type: String
        let columns: Int
        let rows: Int
        let cellWidthPixels: Int
        let cellHeightPixels: Int

        enum CodingKeys: String, CodingKey {
            case type
            case columns = "cols"
            case rows
            case cellWidthPixels = "cell_width_px"
            case cellHeightPixels = "cell_height_px"
        }
    }

    private struct ReleaseCommand: Encodable {
        let type: String
    }
}

/// Incremental decoder for the NDJSON stream emitted by a terminal session.
public struct TerminalSessionRecordDecoder: Sendable {
    public let maximumRecordBytes: Int
    private var buffer = Data()

    /// Herdr permits a 32 MiB binary graphics frame. Base64 expands that by
    /// one third, so the NDJSON envelope needs a larger but still bounded cap.
    public init(maximumRecordBytes: Int = 48 * 1024 * 1024) {
        self.maximumRecordBytes = max(maximumRecordBytes, 1)
    }

    public var hasBufferedBytes: Bool { !buffer.isEmpty }

    public mutating func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= maximumRecordBytes || buffer.contains(0x0A) else {
            throw TerminalSessionWireError.recordTooLarge(limit: maximumRecordBytes)
        }
    }

    public mutating func nextRecord() throws -> TerminalSessionRecord? {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let record = Data(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
            if record.isEmpty || record == Data([0x0D]) { continue }
            guard record.count <= maximumRecordBytes else {
                throw TerminalSessionWireError.recordTooLarge(limit: maximumRecordBytes)
            }
            return try TerminalSessionWire.decodeRecord(record)
        }
        if buffer.count > maximumRecordBytes {
            throw TerminalSessionWireError.recordTooLarge(limit: maximumRecordBytes)
        }
        return nil
    }
}
