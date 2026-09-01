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
        case busy
        case closed
    }

    private let connection: NWConnection
    private unowned let server: FleetBridgeServer
    private let queue: DispatchQueue
    private var decoder = FleetBridgeRecordDecoder()
    private var stage: Stage = .hello
    private var handshakeTimeout: Task<Void, Never>?

    init(
        connection: NWConnection,
        server: FleetBridgeServer,
        queue: DispatchQueue
    ) {
        self.connection = connection
        self.server = server
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self.close() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
        handshakeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, self.isAwaitingAuthentication else { return }
            self.fail(
                code: "handshake_timeout",
                message: "Bridge authentication timed out.",
                fatal: true
            )
        }
    }

    func close() {
        guard !isClosed else { return }
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        if case .terminal(_, let process) = stage {
            process.stop()
        }
        stage = .closed
        connection.cancel()
        server.removeConnection(self)
    }

    func sendSubscribedSnapshot(encodedSnapshot: Data) {
        guard case .subscribed(let requestID) = stage else { return }
        do {
            sendEncoded(
                try FleetBridgeWire.encodeSnapshot(
                    requestID: requestID,
                    encodedSnapshot: encodedSnapshot
                )
            )
        } catch {
            fleetBridgeLog.error(
                "could not encode subscribed snapshot: \(error.localizedDescription)"
            )
            close()
        }
    }

    private var isClosed: Bool {
        if case .closed = stage { return true }
        return false
    }

    private var isAwaitingAuthentication: Bool {
        switch stage {
        case .hello, .authenticate:
            return true
        default:
            return false
        }
    }

    private func receive() {
        guard !isClosed else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                if let data, !data.isEmpty {
                    await self.consume(data)
                }
                if error != nil || isComplete {
                    self.close()
                } else if !self.isClosed {
                    self.receive()
                }
            }
        }
    }

    private func consume(_ data: Data) async {
        do {
            try decoder.append(data)
            while let line = try decoder.nextRecordData() {
                try await handle(FleetBridgeWire.decodeClient(line))
                if isClosed { return }
            }
        } catch is FleetBridgeAuthenticationError {
            fail(
                code: "authentication_failed",
                message: "Bridge authentication failed.",
                fatal: true
            )
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
                throw FleetBridgeHostError.invalidRequest(
                    "The first record must be bridge.hello."
                )
            }
            guard hello.protocolVersion == FleetBridgeProtocol.version else {
                fail(
                    code: "protocol_mismatch",
                    message: "Bridge protocol \(hello.protocolVersion) is unsupported.",
                    fatal: true
                )
                return
            }
            guard !hello.clientName.isEmpty, hello.clientName.utf8.count <= 256 else {
                throw FleetBridgeHostError.invalidRequest("The client name is invalid.")
            }
            try FleetBridgeAuthenticator.validateNonce(hello.clientNonce)
            let serverNonce = try FleetBridgeAuthenticator.randomNonce()
            let proof = try FleetBridgeAuthenticator.serverProof(
                token: server.currentToken,
                clientID: hello.clientID,
                clientName: hello.clientName,
                serverID: server.serverID,
                clientNonce: hello.clientNonce,
                serverNonce: serverNonce
            )
            stage = .authenticate(hello: hello, serverNonce: serverNonce)
            send(.challenge(FleetBridgeChallenge(
                serverID: server.serverID,
                serverName: server.serverName,
                serverNonce: serverNonce,
                serverProof: proof
            )))

        case .authenticate(let hello, let serverNonce):
            guard case .authenticate(let authentication) = record else {
                throw FleetBridgeHostError.invalidRequest(
                    "The challenge must be followed by bridge.authenticate."
                )
            }
            let expected = try FleetBridgeAuthenticator.clientProof(
                token: server.currentToken,
                clientID: hello.clientID,
                clientName: hello.clientName,
                serverID: server.serverID,
                clientNonce: hello.clientNonce,
                serverNonce: serverNonce
            )
            guard FleetBridgeAuthenticator.verify(
                authentication.clientProof,
                equals: expected
            ) else {
                fail(
                    code: "authentication_failed",
                    message: "Bridge authentication failed.",
                    fatal: true
                )
                return
            }
            handshakeTimeout?.cancel()
            handshakeTimeout = nil
            stage = .operation
            send(.welcome(FleetBridgeWelcome(
                serverID: server.serverID,
                serverName: server.serverName,
                revision: server.currentRevision
            )))

        case .operation:
            switch record {
            case .snapshot(let request):
                stage = .busy
                sendEncoded(
                    try FleetBridgeWire.encodeSnapshot(
                        requestID: request.id,
                        encodedSnapshot: try server.encodedSnapshot()
                    ),
                    closeAfter: true
                )

            case .subscribe(let request):
                stage = .subscribed(requestID: request.id)
                server.registerSubscription(self)
                sendSubscribedSnapshot(encodedSnapshot: try server.encodedSnapshot())

            case .rpc(let request):
                stage = .busy
                do {
                    let result = try await server.performRPC(request)
                    send(.rpc(FleetBridgeRPCResponse(id: request.id, result: result)), closeAfter: true)
                } catch let error as FleetBridgeHostError {
                    fail(
                        requestID: request.id,
                        code: error.code,
                        message: error.localizedDescription,
                        fatal: false,
                        closeAfter: true
                    )
                } catch {
                    fail(
                        requestID: request.id,
                        code: "herdr_error",
                        message: error.localizedDescription,
                        fatal: false,
                        closeAfter: true
                    )
                }

            case .terminalOpen(let request):
                let process = try server.makeTerminalProcess(request: request)
                stage = .terminal(streamID: request.streamID, process: process)
                process.onRecord = { [weak self] record in
                    guard let self else { return }
                    switch record {
                    case .frame(let frame):
                        self.send(.terminalFrame(FleetBridgeTerminalFrameRecord(
                            streamID: request.streamID,
                            frame: frame
                        )))
                    case .closed(let reason):
                        self.send(
                            .terminalClosed(FleetBridgeTerminalClosedRecord(
                                streamID: request.streamID,
                                reason: reason
                            )),
                            closeAfter: true
                        )
                    }
                }
                process.onFailure = { [weak self] error in
                    self?.fail(
                        streamID: request.streamID,
                        code: "terminal_failed",
                        message: error.localizedDescription,
                        fatal: false,
                        closeAfter: true
                    )
                }
                do {
                    try process.start()
                } catch {
                    process.stop()
                    throw FleetBridgeHostError.terminalFailed(error.localizedDescription)
                }

            default:
                throw FleetBridgeHostError.invalidRequest(
                    "Choose snapshot, subscription, RPC, or terminal after authentication."
                )
            }

        case .terminal(let streamID, let process):
            switch record {
            case .terminalInput(let input) where input.streamID == streamID:
                try process.send(input.bytes)
            case .terminalResize(let resize) where resize.streamID == streamID:
                try process.resize(resize.size)
            case .terminalRelease(let release) where release.streamID == streamID:
                process.release()
            default:
                throw FleetBridgeHostError.invalidRequest(
                    "This connection only accepts commands for terminal stream \(streamID)."
                )
            }

        case .subscribed:
            throw FleetBridgeHostError.invalidRequest(
                "A fleet subscription is server-to-client only."
            )

        case .busy:
            throw FleetBridgeHostError.invalidRequest("This bridge operation is already running.")

        case .closed:
            return
        }
    }

    private func send(
        _ record: FleetBridgeServerRecord,
        closeAfter: Bool = false
    ) {
        guard !isClosed else { return }
        let data: Data
        do {
            data = try FleetBridgeWire.encodeServer(record)
        } catch {
            fleetBridgeLog.error("could not encode bridge response: \(error.localizedDescription)")
            close()
            return
        }
        sendEncoded(data, closeAfter: closeAfter)
    }

    private func sendEncoded(
        _ data: Data,
        closeAfter: Bool = false
    ) {
        guard !isClosed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if error != nil || closeAfter {
                    self.close()
                }
            }
        })
    }

    private func fail(
        requestID: UUID? = nil,
        streamID: UUID? = nil,
        code: String,
        message: String,
        fatal: Bool,
        closeAfter: Bool = true
    ) {
        send(
            .error(FleetBridgeErrorRecord(
                requestID: requestID,
                streamID: streamID,
                code: code,
                message: message,
                fatal: fatal
            )),
            closeAfter: closeAfter
        )
    }
}
