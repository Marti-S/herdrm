import Foundation
import HerdrKit

/// Owns one `herdr terminal session observe/control` subprocess. The process is
/// local for this Mac's session and OpenSSH-backed for a remote HerdrM device.
@MainActor
final class FleetBridgeTerminalProcess {
    let mode: TerminalSessionMode
    let streamID: UUID

    var onRecord: ((TerminalSessionRecord) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let command: TerminalCommand
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "dev.bybee.herdrm.bridge-terminal-write")
    private var decoder = TerminalSessionRecordDecoder()
    private var stderr = Data()
    private var closed = false

    init(
        streamID: UUID,
        mode: TerminalSessionMode,
        command: TerminalCommand
    ) {
        self.streamID = streamID
        self.mode = mode
        self.command = command
    }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.args
        process.environment = command.environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.ingest(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.ingestError(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in self?.terminated(status: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            cleanupAuthorization()
            throw error
        }
    }

    func send(_ data: Data) throws {
        guard mode.allowsInput else { throw TerminalSessionError.readOnly }
        guard !closed else { throw TerminalSessionError.closed }
        enqueue(try TerminalSessionWire.encodeInput(data))
    }

    func resize(_ size: TerminalSize) throws {
        guard mode.allowsResize else { throw TerminalSessionError.readOnly }
        guard !closed else { throw TerminalSessionError.closed }
        enqueue(try TerminalSessionWire.encodeResize(size))
    }

    func release() {
        guard !closed else { return }
        if mode.access == .control, let data = try? TerminalSessionWire.encodeRelease() {
            try? inputPipe.fileHandleForWriting.write(contentsOf: data)
        }
        onRecord?(.closed(reason: "released"))
        stop()
    }

    func stop() {
        guard !closed else { return }
        closed = true
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? inputPipe.fileHandleForWriting.close()
        cleanupAuthorization()
    }

    private func enqueue(_ data: Data) {
        let handle = inputPipe.fileHandleForWriting
        writeQueue.async { [weak self] in
            do {
                try handle.write(contentsOf: data)
            } catch {
                Task { @MainActor in self?.fail(error) }
            }
        }
    }

    private func ingest(_ data: Data) {
        guard !closed else { return }
        if data.isEmpty {
            return
        }
        do {
            try decoder.append(data)
            while let record = try decoder.nextRecord() {
                onRecord?(record)
                if case .closed = record {
                    finishAfterRemoteClose()
                }
            }
        } catch {
            fail(error)
        }
    }

    private func ingestError(_ data: Data) {
        guard !data.isEmpty, stderr.count < 16 * 1024 else { return }
        stderr.append(data.prefix(16 * 1024 - stderr.count))
    }

    private func terminated(status: Int32) {
        cleanupAuthorization()
        guard !closed else { return }
        closed = true
        let detail = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0 {
            onRecord?(.closed(reason: detail?.isEmpty == false ? detail : nil))
        } else {
            let message = detail?.isEmpty == false
                ? detail!
                : "terminal session exited with status \(status)"
            onFailure?(FleetBridgeHostError.terminalFailed(message))
        }
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        onFailure?(error)
        stop()
    }

    private func finishAfterRemoteClose() {
        guard !closed else { return }
        closed = true
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        cleanupAuthorization()
    }

    private func cleanupAuthorization() {
        guard let authorizationID = command.authorizationID else { return }
        try? SSHCredentialStore.removeAuthorization(authorizationID)
    }
}
