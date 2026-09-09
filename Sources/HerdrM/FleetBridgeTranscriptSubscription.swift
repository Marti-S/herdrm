import Foundation
import HerdrKit

private actor FleetBridgeTranscriptEncoder {
    private let requestID: UUID
    private var previous: TerminalReadResult?
    private var sequence: UInt64 = 0
    init(requestID: UUID) { self.requestID = requestID }

    func update(_ result: JSONValue) throws -> FleetBridgeServerRecord? {
        struct Envelope: Decodable { let read: TerminalReadResult }
        let next = try JSONDecoder().decode(Envelope.self, from: JSONEncoder().encode(result)).read
        if let previous,
           previous.text == next.text && previous.truncated == next.truncated,
           previous.paneID == next.paneID && previous.workspaceID == next.workspaceID,
           previous.tabID == next.tabID && previous.source == next.source && previous.format == next.format {
            self.previous = next
            return nil
        }
        let update: TerminalTranscriptUpdate
        if let previous {
            update = TerminalTranscriptUpdate(sequence: sequence &+ 1, baseSequence: sequence, previous: previous, next: next)
        } else {
            update = TerminalTranscriptUpdate(sequence: 1, read: next)
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(update))
        sequence = update.sequence
        previous = next
        return .rpc(FleetBridgeRPCResponse(id: requestID, result: value))
    }
}

/// A dedicated read-only subscription. Terminal frames invalidate the readable
/// pane snapshot; only changed text is sent, normally as a small UTF-8 patch.
/// Old daemons lacking observe support fall back to host-side polling.
@MainActor
final class FleetBridgeTranscriptSubscription {
    private unowned let server: FleetBridgeServer
    private let request: FleetBridgeRPCRequest
    private let paneID: String
    private let lines: Int
    private let send: (FleetBridgeServerRecord) async throws -> Void
    private let ended: () -> Void
    private let encoder: FleetBridgeTranscriptEncoder
    private var process: FleetBridgeTerminalProcess?
    private var fallbackTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var closed = false
    private lazy var refreshes = RefreshCoalescer { [weak self] in await self?.refresh() }

    init(
        server: FleetBridgeServer, request: FleetBridgeRPCRequest,
        send: @escaping (FleetBridgeServerRecord) async throws -> Void,
        ended: @escaping () -> Void
    ) throws {
        guard case .string(let paneID)? = request.params["pane_id"], !paneID.isEmpty else {
            throw FleetBridgeHostError.invalidRequest("A transcript subscription requires pane_id.")
        }
        let lines: Int
        if let value = request.params["lines"] {
            guard case .number(let number) = value, let count = Int(exactly: number), (1...250).contains(count) else {
                throw FleetBridgeHostError.invalidRequest("Transcript lines must be an integer between 1 and 250.")
            }
            lines = count
        } else { lines = 250 }
        self.server = server
        self.request = request
        self.paneID = paneID
        self.lines = lines
        self.send = send
        self.ended = ended
        encoder = FleetBridgeTranscriptEncoder(requestID: request.id)
    }

    func start() async throws {
        let process = try server.makeTerminalProcess(request: FleetBridgeTerminalOpenRequest(
            deviceID: request.deviceID, target: FleetTerminalTarget(.agent(paneID: paneID)),
            mode: .observe, size: TerminalSize(columns: 80, rows: 24)
        ))
        self.process = process
        process.onRecord = { [weak self] record in
            guard let self, !self.closed else { return }
            switch record {
            case .frame(let frame):
                if !frame.bytes.isEmpty { await self.refreshes.invalidate() }
            case .closed:
                await self.finishWithError(TerminalSessionError.closed)
            }
        }
        process.onFailure = { [weak self] _ in self?.beginFallback() }
        do { try process.start() } catch { beginFallback() }
        // The observer exists before the initial read, avoiding a lost-update gap.
        await refreshes.invalidate(immediate: true)
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, !self.closed else { return }
                do {
                    try await self.send(.rpc(FleetBridgeRPCResponse(id: self.request.id, result: .object(["heartbeat": .bool(true)]))))
                } catch { self.stop(); self.ended(); return }
            }
        }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        fallbackTask?.cancel()
        heartbeatTask?.cancel()
        fallbackTask = nil
        heartbeatTask = nil
        process?.stop()
        process = nil
        let refreshes = refreshes
        Task { await refreshes.cancel() }
    }

    private func beginFallback() {
        guard !closed, fallbackTask == nil else { return }
        process?.stop()
        process = nil
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.closed else { return }
                await self.refreshes.invalidate(immediate: true)
                do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            }
        }
    }

    private func refresh() async {
        guard !closed else { return }
        let interval = PerformanceInterval("HostTranscriptRead")
        defer { interval.end() }
        do {
            let result = try await server.performRPC(FleetBridgeRPCRequest(
                deviceID: request.deviceID, method: "pane.read", params: .object([
                    "pane_id": .string(paneID), "lines": .number(Double(lines)),
                    "source": .string(TerminalReadSource.recentUnwrapped.rawValue),
                    "format": .string(TerminalReadFormat.text.rawValue), "strip_ansi": .bool(true)
                ])
            ))
            guard !closed, !Task.isCancelled else { return }
            if let record = try await encoder.update(result) {
                guard !closed, !Task.isCancelled else { return }
                try await send(record)
            }
        } catch {
            if !closed, !Task.isCancelled { await finishWithError(error) }
        }
    }

    private func finishWithError(_ error: Error) async {
        guard !closed else { return }
        try? await send(.error(FleetBridgeErrorRecord(
            requestID: request.id, code: "transcript_failed", message: error.localizedDescription
        )))
        stop()
        ended()
    }
}
