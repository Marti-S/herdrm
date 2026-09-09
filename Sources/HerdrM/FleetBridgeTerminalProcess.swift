import Darwin
import Foundation
import HerdrKit

/// A single blocking pipe operation lives on a dedicated dispatch queue, not
/// the cooperative executor. The next stdout read starts only after its decoded
/// records have reached the bounded bridge writer.
private final class FleetBridgePipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "dev.bybee.herdrm.bridge-pipe-read")
    init(_ handle: FileHandle) { self.handle = handle }
    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                var count: Int
                repeat {
                    count = Darwin.read(self.handle.fileDescriptor, &bytes, bytes.count)
                } while count < 0 && errno == EINTR
                if count < 0 {
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                } else {
                    continuation.resume(returning: Data(bytes.prefix(count)))
                }
            }
        }
    }
}

/// Owns one read-only/control Herdr subprocess. Process lifecycle remains on
/// the main actor; stdout decoding runs in one ordered, backpressured worker.
@MainActor
final class FleetBridgeTerminalProcess {
    let mode: TerminalSessionMode
    let streamID: UUID
    var onRecord: ((TerminalSessionRecord) async -> Void)?
    var onFailure: ((Error) async -> Void)?

    private let command: TerminalCommand
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "dev.bybee.herdrm.bridge-terminal-write")
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var stderr = Data()
    private var closed = false

    init(streamID: UUID, mode: TerminalSessionMode, command: TerminalCommand) {
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
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                // Process exit can arrive before the pipe's final bytes.
                await self.outputTask?.value
                await self.errorTask?.value
                await self.terminated(status: status)
            }
        }
        do { try process.run() }
        catch { cleanupAuthorization(); throw error }

        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        try? inputPipe.fileHandleForReading.close()
        let output = FleetBridgePipeReader(outputPipe.fileHandleForReading)
        outputTask = Task.detached(priority: .userInitiated) { [weak self] in
            var decoder = TerminalSessionRecordDecoder()
            do {
                while !Task.isCancelled {
                    let data = try await output.read()
                    guard !data.isEmpty, !Task.isCancelled else { break }
                    try decoder.append(data)
                    while !Task.isCancelled, let record = try decoder.nextRecord() {
                        await self?.deliver(record)
                        if case .closed = record { return }
                    }
                }
            } catch {
                if !Task.isCancelled { await self?.fail(error) }
            }
        }
        let errors = FleetBridgePipeReader(errorPipe.fileHandleForReading)
        errorTask = Task.detached { [weak self] in
            var bounded = Data()
            do {
                while !Task.isCancelled {
                    let data = try await errors.read()
                    guard !data.isEmpty else { break }
                    if bounded.count < 16 * 1024 { bounded.append(data.prefix(16 * 1024 - bounded.count)) }
                }
            } catch {}
            await self?.setStderr(bounded)
        }
    }

    func send(_ data: Data) async throws {
        guard mode.allowsInput else { throw TerminalSessionError.readOnly }
        guard !closed else { throw TerminalSessionError.closed }
        try await write(TerminalSessionWire.encodeInput(data))
    }

    func resize(_ size: TerminalSize) async throws {
        guard mode.allowsResize else { throw TerminalSessionError.readOnly }
        guard !closed else { throw TerminalSessionError.closed }
        try await write(TerminalSessionWire.encodeResize(size))
    }

    func release() async {
        guard !closed else { return }
        if mode.access == .control { try? await write(TerminalSessionWire.encodeRelease()) }
        await onRecord?(.closed(reason: "released"))
        stop()
    }

    func stop() {
        guard !closed else { return }
        closed = true
        outputTask?.cancel()
        errorTask?.cancel()
        if process.isRunning {
            process.terminate()
            let process = process
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        try? inputPipe.fileHandleForWriting.close()
        // Close parent-owned write ends too, so pending pipe reads can see EOF.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        cleanupAuthorization()
    }

    private func write(_ data: Data) async throws {
        let handle = inputPipe.fileHandleForWriting
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do { try handle.write(contentsOf: data); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func deliver(_ record: TerminalSessionRecord) async {
        guard !closed else { return }
        await onRecord?(record)
        if case .closed = record { stop() }
    }

    private func setStderr(_ data: Data) { stderr = data }

    private func terminated(status: Int32) async {
        guard !closed else { return }
        let detail = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0 {
            await onRecord?(.closed(reason: detail?.isEmpty == false ? detail : nil))
        } else {
            let message = detail?.isEmpty == false ? detail! : "terminal session exited with status \(status)"
            await onFailure?(FleetBridgeHostError.terminalFailed(message))
        }
        stop()
    }

    private func fail(_ error: Error) async {
        guard !closed else { return }
        await onFailure?(error)
        stop()
    }

    private func cleanupAuthorization() {
        guard let authorizationID = command.authorizationID else { return }
        try? SSHCredentialStore.removeAuthorization(authorizationID)
    }
}
