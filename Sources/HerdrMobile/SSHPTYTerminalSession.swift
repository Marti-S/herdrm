import Foundation
import HerdrKit
import HerdrSSH

/// Adapts the current direct-SSH PTY implementation to the transport-neutral
/// terminal session surface. Bootstrap filtering lives here so a future bridge
/// session can deliver already-clean Herdr terminal frames.
actor SSHPTYTerminalSession: TerminalSession {
    nonisolated let mode: TerminalSessionMode

    private let channel: SSHPTYChannel
    private var size: TerminalSize
    private var nextSequence: UInt64 = 0
    private var sawBootstrapMarker = false
    private var bootstrapBuffer = Data()
    private var closed = false

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
            guard let data = try await channel.read(timeout: .seconds(3600)) else {
                if !sawBootstrapMarker, !bootstrapBuffer.isEmpty {
                    sawBootstrapMarker = true
                    let buffered = bootstrapBuffer
                    bootstrapBuffer.removeAll()
                    return makeFrame(buffered)
                }
                return nil
            }
            guard !data.isEmpty else { continue }

            if sawBootstrapMarker {
                return makeFrame(data)
            }

            bootstrapBuffer.append(data)
            if let range = bootstrapBuffer.firstRange(of: MobileAttach.bootstrapMarker) {
                sawBootstrapMarker = true
                let payload = Data(bootstrapBuffer.suffix(from: range.upperBound))
                bootstrapBuffer.removeAll()
                if !payload.isEmpty {
                    return makeFrame(payload)
                }
                continue
            }

            // An old or failed remote command may never print the marker. Keep
            // the gate bounded so its diagnostic output still reaches the user.
            if bootstrapBuffer.count > 8192 {
                sawBootstrapMarker = true
                let buffered = bootstrapBuffer
                bootstrapBuffer.removeAll()
                return makeFrame(buffered)
            }
        }
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw TerminalSessionError.closed }
        guard mode.allowsInput else { throw TerminalSessionError.readOnly }
        guard !data.isEmpty else { return }
        try await channel.write(data, timeout: .seconds(10))
    }

    func resize(_ size: TerminalSize) async throws {
        guard !closed else { throw TerminalSessionError.closed }
        guard mode.allowsResize else { throw TerminalSessionError.readOnly }
        guard size.isValid else { throw TerminalSessionError.invalidSize }

        try await channel.resize(
            columns: size.columns,
            rows: size.rows,
            timeout: .seconds(5)
        )
        self.size = size
    }

    func close() async {
        guard !closed else { return }
        closed = true
        try? await channel.close(timeout: .seconds(2))
    }

    private func makeFrame(_ bytes: Data) -> TerminalFrame {
        nextSequence &+= 1
        return TerminalFrame(
            sequence: nextSequence,
            width: size.columns,
            height: size.rows,
            bytes: bytes
        )
    }
}
