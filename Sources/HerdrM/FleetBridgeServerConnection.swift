import Foundation
import HerdrKit
import Network

@MainActor
final class FleetBridgeServerConnection {
    let id = UUID()
    private enum Stage {
        case hello
        case authenticate(hello: FleetBridgeHello, serverNonce: Data)
        case operation
        case subscribed(requestID: UUID)
        case terminal(streamID: UUID, process: FleetBridgeTerminalProcess)
        case transcript(FleetBridgeTranscriptSubscription)
        case busy
        case closed
    }
    private let connection: NWConnection
    private unowned let server: FleetBridgeServer
    private let queue: DispatchQueue
    private let io: FleetBridgeConnectionIO
    private var stage: Stage = .hello
    private var persistentRPC = false
    private var handshakeTimeout: Task<Void, Never>?
    private var rpcTasks: [UUID: Task<Void, Never>] = [:]
    private var writes: [UUID: Task<Void, Never>] = [:]
    private var pendingSnapshot: Data?
    private var snapshotTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    init(connection: NWConnection, server: FleetBridgeServer, queue: DispatchQueue) {
        self.connection = connection; self.server = server; self.queue = queue
        io = FleetBridgeConnectionIO(connection: connection)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in self?.close() }
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
        handshakeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, self.isAwaitingAuthentication else { return }
            self.fail(code: "handshake_timeout", message: "Bridge authentication timed out.", fatal: true)
        }
    }

    func close() {
        guard !isClosed else { return }
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        switch stage {
        case .terminal(_, let process): process.stop()
        case .transcript(let subscription): subscription.stop()
        default: break
        }
        stage = .closed
        connection.cancel()
        for task in rpcTasks.values { task.cancel() }
        for task in writes.values { task.cancel() }
        rpcTasks.removeAll()
        writes.removeAll()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        pendingSnapshot = nil
        let io = io
        Task { await io.close() }
        server.removeConnection(self)
    }

    func sendSubscribedSnapshot(encodedSnapshot: Data) {
        guard case .subscribed = stage else { return }
        // These are complete fleet snapshots, so a slow client only needs the
        // newest unsent value, not an ever-growing queue of obsolete states.
        pendingSnapshot = encodedSnapshot
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            defer { self.snapshotTask = nil }
            while let data = self.pendingSnapshot, case .subscribed(let requestID) = self.stage {
                self.pendingSnapshot = nil
                do { try await self.io.sendSnapshot(requestID: requestID, encodedSnapshot: data) }
                catch { self.close(); return }
            }
        }
    }

    private var isClosed: Bool { if case .closed = stage { return true }; return false }
    private var isAwaitingAuthentication: Bool {
        switch stage { case .hello, .authenticate: return true; default: return false }
    }

    private func receive() {
        guard !isClosed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                if let data, !data.isEmpty { await self.consume(data) }
                if error != nil || complete { self.close() }
                else if !self.isClosed { self.receive() }
            }
        }
    }

    private func consume(_ data: Data) async {
        do {
            for record in try await io.consume(data) {
                guard !isClosed else { return }
                try await handle(record)
            }
        } catch is FleetBridgeAuthenticationError {
            fail(code: "authentication_failed", message: "Bridge authentication failed.", fatal: true)
        } catch let error as FleetBridgeHostError {
            fail(code: error.code, message: error.localizedDescription, fatal: true)
        } catch let error as FleetBridgeWireError {
            fail(code: "protocol_error", message: error.localizedDescription, fatal: true)
        } catch {
            fail(code: "bridge_error", message: error.localizedDescription, fatal: true)
        }
    }

    private func handle(_ record: FleetBridgeClientRecord) async throws {
        switch stage {
        case .hello:
            guard case .hello(let hello) = record else {
                throw FleetBridgeHostError.invalidRequest("The first record must be bridge.hello.")
            }
            guard hello.protocolVersion == FleetBridgeProtocol.version else {
                fail(code: "protocol_mismatch", message: "Bridge protocol \(hello.protocolVersion) is unsupported.", fatal: true)
                return
            }
            guard !hello.clientName.isEmpty, hello.clientName.utf8.count <= 256 else {
                throw FleetBridgeHostError.invalidRequest("The client name is invalid.")
            }
            try FleetBridgeAuthenticator.validateNonce(hello.clientNonce)
            let serverNonce = try FleetBridgeAuthenticator.randomNonce()
            let proof = try FleetBridgeAuthenticator.serverProof(
                token: server.currentToken, clientID: hello.clientID, clientName: hello.clientName,
                serverID: server.serverID, clientNonce: hello.clientNonce, serverNonce: serverNonce
            )
            stage = .authenticate(hello: hello, serverNonce: serverNonce)
            send(.challenge(FleetBridgeChallenge(
                serverID: server.serverID, serverName: server.serverName, serverNonce: serverNonce, serverProof: proof
            )))

        case .authenticate(let hello, let serverNonce):
            guard case .authenticate(let authentication) = record else {
                throw FleetBridgeHostError.invalidRequest("The challenge must be followed by bridge.authenticate.")
            }
            let expected = try FleetBridgeAuthenticator.clientProof(
                token: server.currentToken, clientID: hello.clientID, clientName: hello.clientName,
                serverID: server.serverID, clientNonce: hello.clientNonce, serverNonce: serverNonce
            )
            guard FleetBridgeAuthenticator.verify(authentication.clientProof, equals: expected) else {
                fail(code: "authentication_failed", message: "Bridge authentication failed.", fatal: true)
                return
            }
            handshakeTimeout?.cancel()
            handshakeTimeout = nil
            stage = .operation
            send(.welcome(FleetBridgeWelcome(serverID: server.serverID, serverName: server.serverName, revision: server.currentRevision)))

        case .operation:
            switch record {
            case .snapshot(let request):
                guard !persistentRPC else { throw FleetBridgeHostError.invalidRequest("Use a separate snapshot connection.") }
                stage = .busy
                let snapshot = try server.encodedSnapshot()
                enqueueWrite(closeAfter: true) {
                    try await self.io.sendSnapshot(requestID: request.id, encodedSnapshot: snapshot)
                }
            case .subscribe(let request):
                guard !persistentRPC else { throw FleetBridgeHostError.invalidRequest("Use a separate subscription connection.") }
                stage = .subscribed(requestID: request.id)
                server.registerSubscription(self)
                sendSubscribedSnapshot(encodedSnapshot: try server.encodedSnapshot())
                heartbeatTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(15)) } catch { return }
                        guard let self, !self.isClosed else { return }
                        do {
                            try await self.sendAwaiting(.rpc(FleetBridgeRPCResponse(
                                id: request.id, result: .object(["heartbeat": .bool(true)])
                            )))
                        } catch { return }
                    }
                }
            case .rpc(let request):
                try await handleRPC(request)
            case .terminalOpen(let request):
                guard !persistentRPC else { throw FleetBridgeHostError.invalidRequest("Use a separate terminal connection.") }
                let process = try server.makeTerminalProcess(request: request)
                stage = .terminal(streamID: request.streamID, process: process)
                process.onRecord = { [weak self] record in
                    guard let self, !self.isClosed else { return }
                    do {
                        switch record {
                        case .frame(let frame):
                            try await self.sendAwaiting(.terminalFrame(FleetBridgeTerminalFrameRecord(streamID: request.streamID, frame: frame)))
                        case .closed(let reason):
                            try await self.sendAwaiting(.terminalClosed(FleetBridgeTerminalClosedRecord(streamID: request.streamID, reason: reason)))
                            self.close()
                        }
                    } catch { self.close() }
                }
                process.onFailure = { [weak self] error in
                    guard let self else { return }
                    self.fail(streamID: request.streamID, code: "terminal_failed", message: error.localizedDescription, fatal: false)
                }
                do { try process.start() }
                catch { process.stop(); throw FleetBridgeHostError.terminalFailed(error.localizedDescription) }
            default:
                throw FleetBridgeHostError.invalidRequest("Choose snapshot, subscription, RPC, or terminal after authentication.")
            }

        case .terminal(let streamID, let process):
            switch record {
            case .terminalInput(let input) where input.streamID == streamID: try await process.send(input.bytes)
            case .terminalResize(let resize) where resize.streamID == streamID: try await process.resize(resize.size)
            case .terminalRelease(let release) where release.streamID == streamID: await process.release()
            default: throw FleetBridgeHostError.invalidRequest("This connection only accepts commands for terminal stream \(streamID).")
            }
        case .subscribed, .transcript:
            throw FleetBridgeHostError.invalidRequest("A subscription is server-to-client only.")
        case .busy:
            throw FleetBridgeHostError.invalidRequest("This bridge operation is already running.")
        case .closed: return
        }
    }

    private func handleRPC(_ request: FleetBridgeRPCRequest) async throws {
        if request.method == FleetBridgePerformanceProtocol.capabilitiesMethod {
            guard !persistentRPC else { throw FleetBridgeHostError.invalidRequest("Capabilities are already negotiated.") }
            persistentRPC = true
            send(.rpc(FleetBridgeRPCResponse(id: request.id, result: .object([
                "persistent_rpc": .bool(true), "pane_transcript": .bool(true)
            ]))))
            return
        }
        if request.method == FleetBridgePerformanceProtocol.transcriptMethod {
            guard !persistentRPC else { throw FleetBridgeHostError.invalidRequest("Use a separate transcript connection.") }
            let subscription = try FleetBridgeTranscriptSubscription(
                server: server, request: request,
                send: { [weak self] record in
                    guard let self else { throw TerminalSessionError.closed }
                    try await self.sendAwaiting(record)
                },
                ended: { [weak self] in self?.close() }
            )
            stage = .transcript(subscription)
            try await subscription.start()
            return
        }
        if persistentRPC {
            if request.method == FleetBridgePerformanceProtocol.pingMethod {
                send(.rpc(FleetBridgeRPCResponse(id: request.id, result: .object(["alive": .bool(true)]))))
                return
            }
            guard rpcTasks[request.id] == nil else { throw FleetBridgeHostError.invalidRequest("Duplicate in-flight request ID.") }
            guard rpcTasks.count < FleetBridgePerformanceProtocol.maximumInFlightRequests else {
                fail(requestID: request.id, code: "overloaded", message: "Too many bridge requests are in flight.", fatal: false, closeAfter: false)
                return
            }
            rpcTasks[request.id] = Task { [weak self] in
                guard let self else { return }
                defer { self.rpcTasks.removeValue(forKey: request.id) }
                await self.performRPC(request, closeAfter: false)
            }
        } else {
            // Existing v2 clients never negotiate capabilities; preserve their
            // close-after-one-operation behavior exactly.
            stage = .busy
            await performRPC(request, closeAfter: true)
        }
    }

    private func performRPC(_ request: FleetBridgeRPCRequest, closeAfter: Bool) async {
        do {
            let result = try await server.performRPC(request)
            guard !isClosed, !Task.isCancelled else { return }
            try await sendAwaiting(.rpc(FleetBridgeRPCResponse(id: request.id, result: result)))
            if closeAfter { close() }
        } catch {
            guard !isClosed, !Task.isCancelled else { return }
            fail(requestID: request.id, code: (error as? FleetBridgeHostError)?.code ?? "herdr_error",
                 message: error.localizedDescription, fatal: false, closeAfter: closeAfter)
        }
    }

    private func sendAwaiting(_ record: FleetBridgeServerRecord) async throws {
        guard !isClosed else { throw TerminalSessionError.closed }
        do { try await io.send(record) }
        catch { close(); throw error }
    }

    private func send(_ record: FleetBridgeServerRecord, closeAfter: Bool = false) {
        enqueueWrite(closeAfter: closeAfter) { try await self.io.send(record) }
    }

    private func sendEncoded(_ data: Data, closeAfter: Bool = false) {
        enqueueWrite(closeAfter: closeAfter) { try await self.io.sendEncoded(data) }
    }

    private func enqueueWrite(closeAfter: Bool, operation: @escaping () async throws -> Void) {
        guard !isClosed else { return }
        guard writes.count < 128 else { close(); return }
        let id = UUID()
        writes[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.writes.removeValue(forKey: id) }
            do { try await operation(); if closeAfter { self.close() } }
            catch { self.close() }
        }
    }

    private func fail(
        requestID: UUID? = nil, streamID: UUID? = nil, code: String, message: String,
        fatal: Bool, closeAfter: Bool = true
    ) {
        send(.error(FleetBridgeErrorRecord(requestID: requestID, streamID: streamID, code: code, message: message, fatal: fatal)), closeAfter: closeAfter)
    }
}
