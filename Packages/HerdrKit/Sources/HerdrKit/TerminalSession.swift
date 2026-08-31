import Foundation

/// Grid dimensions negotiated for a live terminal session.
///
/// Pixel dimensions are optional. A value of zero means the transport does not
/// know the physical cell size.
public struct TerminalSize: Codable, Sendable, Equatable {
    public let columns: Int
    public let rows: Int
    public let cellWidthPixels: Int
    public let cellHeightPixels: Int

    public init(
        columns: Int,
        rows: Int,
        cellWidthPixels: Int = 0,
        cellHeightPixels: Int = 0
    ) {
        self.columns = columns
        self.rows = rows
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels
    }

    public var isValid: Bool {
        columns > 0
            && rows > 0
            && cellWidthPixels >= 0
            && cellHeightPixels >= 0
    }

    enum CodingKeys: String, CodingKey {
        case columns = "cols"
        case rows
        case cellWidthPixels = "cell_width_px"
        case cellHeightPixels = "cell_height_px"
    }
}

/// Whether a client watches a terminal or owns its interactive input lease.
public struct TerminalSessionMode: Codable, Sendable, Equatable {
    public enum Access: String, Codable, Sendable {
        case observe
        case control
    }

    public let access: Access
    public let takeover: Bool

    public init(access: Access, takeover: Bool = false) {
        self.access = access
        self.takeover = access == .control && takeover
    }

    public static let observe = TerminalSessionMode(access: .observe)

    public static func control(takeover: Bool = false) -> TerminalSessionMode {
        TerminalSessionMode(access: .control, takeover: takeover)
    }

    public var allowsInput: Bool { access == .control }
    public var allowsResize: Bool { access == .control }
}

/// Encoding carried by a terminal frame.
public enum TerminalFrameEncoding: String, Codable, Sendable {
    case ansi
}

/// One ordered terminal update.
///
/// The field names match Herdr's existing `terminal.frame` JSON envelope, so a
/// structured SSH or bridge transport can decode it without an extra model.
public struct TerminalFrame: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let encoding: TerminalFrameEncoding
    public let width: Int
    public let height: Int
    public let isFull: Bool
    public let bytes: Data

    public init(
        sequence: UInt64,
        encoding: TerminalFrameEncoding = .ansi,
        width: Int,
        height: Int,
        isFull: Bool = false,
        bytes: Data
    ) {
        self.sequence = sequence
        self.encoding = encoding
        self.width = width
        self.height = height
        self.isFull = isFull
        self.bytes = bytes
    }

    public var size: TerminalSize {
        TerminalSize(columns: width, rows: height)
    }

    enum CodingKeys: String, CodingKey {
        case sequence = "seq"
        case encoding
        case width
        case height
        case isFull = "full"
        case bytes
    }
}

public enum TerminalSessionError: Error, LocalizedError, Sendable, Equatable {
    case readOnly
    case closed
    case invalidSize

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            return "This terminal session is read-only."
        case .closed:
            return "This terminal session is closed."
        case .invalidSize:
            return "Terminal columns and rows must be greater than zero."
        }
    }
}

/// Transport-neutral live terminal surface.
///
/// The direct SSH implementation adapts an SSH PTY. A bridge transport can
/// instead adapt Herdr's structured terminal observe/control stream while the
/// UI continues to consume the same ordered ANSI frames.
public protocol TerminalSession: Sendable {
    var mode: TerminalSessionMode { get }

    /// Returns the next terminal frame, or nil after orderly remote closure.
    func read() async throws -> TerminalFrame?

    /// Sends raw terminal bytes when this session owns control.
    func send(_ data: Data) async throws

    /// Changes the controller's terminal grid.
    func resize(_ size: TerminalSize) async throws

    /// Releases control and closes transport resources. Idempotent.
    func close() async
}
