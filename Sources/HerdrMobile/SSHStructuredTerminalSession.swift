import Foundation
import HerdrKit
import HerdrSSH

private enum SSHStructuredTerminalSessionError: Error, LocalizedError {
    case bootstrapFailed(String)
    case closed(String)
    case unexpectedEOF

    var errorDescription: String? {
        switch self {
        case .bootstrapFailed(let detail):
            return detail.isEmpty
                ? String(localized: "The remote terminal session did not start.")
                : detail
        case .closed(let reason):
            return reason
        case .unexpectedEOF:
            return String(localized: "The remote terminal session ended with an incomplete response.")
        }
    }
}

/// Adapts Herdr's structured `terminal session observe/control` NDJSON stream
/// carried over one SSH PTY. The PTY is configured without echo or output
/// processing by `MobileAttach.structuredCommand`, so only protocol records
/// reach this decoder.
actor SSHStructuredTerminalSession: TerminalSession {
    nonisolated let mode: TerminalSessionMode

    private let channel: SSHPTYChannel
    private var size: TerminalSize
    private var sawBootstrapMarker = false
    private var bootstrapBuffer = Data()
    private var decoder = TerminalSessionRecordDecoder()
    private var closed = false
    private var resourcesClosed = false

    init(
        channel: SSHPTYChannel,
        mode: TerminalSessionMode,
        initialSize: TerminalSize
    ) {
        self.channel = channel
        self.mode = mode
        self.size = initialSize
    }

    func read() async throws -> TerminalFrame? {
        guard !closed else { return nil }

        while true {
            if let record = try decoder.nextRecord() {
                switch record {
                case .frame(let frame):
                    size = frame.size
                    return frame
                case .closed(let reason):
                    closed = true
                    if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !reason.isEmpty {
                        throw SSHStructuredTerminalSessionError.closed(reason)
                    }
                    return nil
                }
            }

            guard let data = try await channel.read(timeout: .seconds(3600)) else {
                closed = true
                if !sawBootstrapMarker {
                    throw SSHStructuredTerminalSessionError.bootstrapFailed(
                        Self.diagnostic(from: bootstrapBuffer)
                    )
                }
                if decoder.hasBufferedBytes {
                    throw SSHStructuredTerminalSessionError.unexpectedEOF
                }
                return nil
            }
            guard !data.isEmpty else { continue }
            try ingest(data)
        }
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw TerminalSessionError.closed }
        guard mode.allowsInput else { throw TerminalSessionError.readOnly }
        guard !data.isEmpty else { return }
        try await channel.write(
            TerminalSessionWire.encodeInput(data),
            timeout: .seconds(10)
        )
    }

    func resize(_ size: TerminalSize) async throws {
        guard !closed else { throw TerminalSessionError.closed }
        guard mode.allowsResize else { throw TerminalSessionError.readOnly }
        guard size.isValid else { throw TerminalSessionError.invalidSize }
        try await channel.write(
            TerminalSessionWire.encodeResize(size),
            timeout: .seconds(5)
        )
        self.size = size
    }

    func close() async {
        guard !resourcesClosed else { return }
        resourcesClosed = true
        let shouldRelease = mode.allowsInput && !closed
        closed = true
        if shouldRelease,
           let release = try? TerminalSessionWire.encodeRelease() {
            try? await channel.write(release, timeout: .seconds(1))
        }
        try? await channel.close(timeout: .seconds(2))
    }

    private func ingest(_ data: Data) throws {
        guard !sawBootstrapMarker else {
            try decoder.append(data)
            return
        }

        bootstrapBuffer.append(data)
        if let range = bootstrapBuffer.firstRange(of: MobileAttach.bootstrapMarker) {
            sawBootstrapMarker = true
            let payload = Data(bootstrapBuffer.suffix(from: range.upperBound))
            bootstrapBuffer.removeAll()
            try decoder.append(payload)
            return
        }

        if bootstrapBuffer.count > 8192 {
            throw SSHStructuredTerminalSessionError.bootstrapFailed(
                Self.diagnostic(from: bootstrapBuffer)
            )
        }
    }

    private static func diagnostic(from data: Data) -> String {
        String(decoding: data.suffix(2048), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
