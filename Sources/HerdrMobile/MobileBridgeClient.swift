import Foundation
import HerdrKit
import Network

private final class BridgeContinuationGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(throwing: error)
    }
}

enum MobileBridgeClientError: Error, LocalizedError, Sendable {
    case invalidEndpoint
    case missingToken
    case connectionClosed
    case protocolMismatch(Int)
    case unexpectedRecord
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return String(localized: "The Mac bridge address is invalid.")
        case .missingToken:
            return String(localized: "This Mac has no saved pairing token.")
        case .connectionClosed:
            return String(localized: "The Mac bridge closed the connection.")
        case .protocolMismatch(let version):
            return String(localized: "Mac bridge protocol \(version) is not supported.")
        case .unexpectedRecord:
            return String(localized: "The Mac bridge returned an unexpected response.")
        case .server(_, let message):
            return message
        }
    }
}

/// One authenticated TCP connection to the Mac bridge. Reads are serialized by
/// the actor while terminal writes can interleave during an awaited receive.
actor MobileBridgeConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.bybee.herdrm.ios.bridge")
    private var decoder = FleetBridgeRecordDecoder()
    private var remoteComplete = false
    private var closed = false

    init(endpoint: MobileBridgeEndpoint) throws {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw MobileBridgeClientError.invalidEndpoint
        }
        connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: .tcp
        )
    }

    func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = BridgeContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(returning: ())
                case .failed(let error):
                    gate.resume(throwing: error)
                case .cancelled:
                    gate.resume(throwing: MobileBridgeClientError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func authenticate(token: String) async throws {
        try await send(.hello(FleetBridgeHello(
            token: token,
            clientID: MobileBridgeClientIdentity.id,
            clientName: MobileBridgeClientIdentity.name
        )))
        switch try await nextRecord() {
        case .welcome(let welcome):
            guard welcome.protocolVersion == FleetBridgeProtocol.version else {
                throw MobileBridgeClientError.protocolMismatch(welcome.protocolVersion)
            }
        case .error(let error):
            throw MobileBridgeClientError.server(code: error.code, message: error.message)
        default:
            throw MobileBridgeClientError.unexpectedRecord
        }
    }

    func send(_ record: FleetBridgeClientRecord) async throws {
        guard !closed else { throw MobileBridgeClientError.connectionClosed }
        let data = try FleetBridgeWire.encodeClient(record)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func nextRecord() async throws -> FleetBridgeServerRecord {
        while true {
            if let line = try decoder.nextRecordData() {
                return try FleetBridgeWire.decodeServer(line)
            }
            if remoteComplete {
                throw MobileBridgeClientError.connectionClosed
            }
            let chunk = try await receiveChunk()
            if !chunk.data.isEmpty {
                try decoder.append(chunk.data)
            }
            remoteComplete = chunk.complete
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
    }

    private func receiveChunk() async throws -> (data: Data, complete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1024
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), isComplete))
                }
            }
        }
    }
}

enum MobileBridgeClient {
    static func snapshot(
        endpoint: MobileBridgeEndpoint,
        token: String
    ) async throws -> FleetSnapshot {
        let connection = try await authenticatedConnection(endpoint: endpoint, token: token)
        let request = FleetBridgeSnapshotRequest()
        do {
            try await connection.send(.snapshot(request))
            let record = try await connection.nextRecord()
            await connection.close()
            switch record {
            case .snapshot(let response) where response.requestID == request.id:
                return response.snapshot
            case .error(let error):
                throw MobileBridgeClientError.server(code: error.code, message: error.message)
            default:
                throw MobileBridgeClientError.unexpectedRecord
            }
        } catch {
            await connection.close()
            throw error
        }
    }

    static func snapshots(
        endpoint: MobileBridgeEndpoint,
        token: String,
        afterRevision: UInt64? = nil
    ) -> AsyncThrowingStream<FleetSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var connection: MobileBridgeConnection?
                do {
                    let active = try await authenticatedConnection(endpoint: endpoint, token: token)
                    connection = active
                    let request = FleetBridgeSubscribeRequest(afterRevision: afterRevision)
                    try await active.send(.subscribe(request))
                    while !Task.isCancelled {
                        switch try await active.nextRecord() {
                        case .snapshot(let response) where response.requestID == request.id:
                            continuation.yield(response.snapshot)
                        case .error(let error):
                            throw MobileBridgeClientError.server(
                                code: error.code,
                                message: error.message
                            )
                        default:
                            continue
                        }
                    }
                    await active.close()
                    continuation.finish()
                } catch {
                    if let connection { await connection.close() }
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func request(
        endpoint: MobileBridgeEndpoint,
        token: String,
        deviceID: UUID,
        method: String,
        params: JSONValue
    ) async throws -> JSONValue {
        let connection = try await authenticatedConnection(endpoint: endpoint, token: token)
        let request = FleetBridgeRPCRequest(
            deviceID: deviceID,
            method: method,
            params: params
        )
        do {
            try await connection.send(.rpc(request))
            let record = try await connection.nextRecord()
            await connection.close()
            switch record {
            case .rpc(let response) where response.id == request.id:
                return response.result
            case .error(let error):
                throw MobileBridgeClientError.server(code: error.code, message: error.message)
            default:
                throw MobileBridgeClientError.unexpectedRecord
            }
        } catch {
            await connection.close()
            throw error
        }
    }

    static func openTerminal(
        endpoint: MobileBridgeEndpoint,
        token: String,
        deviceID: UUID,
        target: TerminalAttachTarget,
        mode: TerminalSessionMode,
        size: TerminalSize
    ) async throws -> any TerminalSession {
        guard size.isValid else { throw TerminalSessionError.invalidSize }
        let connection = try await authenticatedConnection(endpoint: endpoint, token: token)
        let request = FleetBridgeTerminalOpenRequest(
            deviceID: deviceID,
            target: FleetTerminalTarget(target),
            mode: mode,
            size: size
        )
        do {
            try await connection.send(.terminalOpen(request))
            return MobileBridgeTerminalSession(
                connection: connection,
                streamID: request.streamID,
                mode: mode
            )
        } catch {
            await connection.close()
            throw error
        }
    }

    private static func authenticatedConnection(
        endpoint: MobileBridgeEndpoint,
        token: String
    ) async throws -> MobileBridgeConnection {
        let connection = try MobileBridgeConnection(endpoint: endpoint)
        do {
            try await connection.start()
            try await connection.authenticate(token: token)
            return connection
        } catch {
            await connection.close()
            throw error
        }
    }
}

actor MobileBridgeTerminalSession: TerminalSession {
    nonisolated let mode: TerminalSessionMode
    private let connection: MobileBridgeConnection
    private let streamID: UUID
    private var closed = false

    init(
        connection: MobileBridgeConnection,
        streamID: UUID,
        mode: TerminalSessionMode
    ) {
        self.connection = connection
        self.streamID = streamID
        self.mode = mode
    }

    func read() async throws -> TerminalFrame? {
        guard !closed else { return nil }
        while true {
            switch try await connection.nextRecord() {
            case .terminalFrame(let record) where record.streamID == streamID:
                return record.frame
            case .terminalClosed(let record) where record.streamID == streamID:
                closed = true
                await connection.close()
                return nil
            case .error(let error) where error.streamID == nil || error.streamID == streamID:
                closed = true
                await connection.close()
                throw MobileBridgeClientError.server(code: error.code, message: error.message)
            default:
                continue
            }
        }
    }

    func send(_ data: Data) async throws {
        guard mode.allowsInput else { throw TerminalSessionError.readOnly }
        guard !closed else { throw TerminalSessionError.closed }
        try await connection.send(.terminalInput(FleetBridgeTerminalInput(
            streamID: streamID,
            bytes: data
        )))
    }

    func resize(_ size: TerminalSize) async throws {
        guard mode.allowsResize else { throw TerminalSessionError.readOnly }
        guard !closed else { throw TerminalSessionError.closed }
        guard size.isValid else { throw TerminalSessionError.invalidSize }
        try await connection.send(.terminalResize(FleetBridgeTerminalResize(
            streamID: streamID,
            size: size
        )))
    }

    func close() async {
        guard !closed else { return }
        closed = true
        if mode.access == .control {
            try? await connection.send(.terminalRelease(FleetBridgeTerminalRelease(
                streamID: streamID
            )))
        }
        await connection.close()
    }
}

/// A device-scoped view of one paired Mac bridge. It satisfies the existing
/// terminal UI contract while all network operations still route through the
/// Mac's aggregate fleet host.
final class BridgeDeviceTransport: MobileTransport {
    let endpoint: MobileBridgeEndpoint
    let deviceID: UUID
    private let token: String

    init(endpoint: MobileBridgeEndpoint, deviceID: UUID, token: String) {
        self.endpoint = endpoint
        self.deviceID = deviceID
        self.token = token
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        try await MobileBridgeClient.request(
            endpoint: endpoint,
            token: token,
            deviceID: deviceID,
            method: method,
            params: params
        )
    }

    func events(kinds: [String]) -> AsyncThrowingStream<HerdrEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await snapshot in MobileBridgeClient.snapshots(
                        endpoint: endpoint,
                        token: token
                    ) {
                        guard snapshot.device(deviceID) != nil else { continue }
                        continuation.yield(HerdrEvent(
                            kind: "fleet.updated",
                            payload: .object([
                                "revision": .number(Double(snapshot.revision)),
                                "device_id": .string(deviceID.uuidString),
                            ])
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func openTerminalSession(
        target: TerminalAttachTarget,
        mode: TerminalSessionMode,
        size: TerminalSize
    ) async throws -> any TerminalSession {
        try await MobileBridgeClient.openTerminal(
            endpoint: endpoint,
            token: token,
            deviceID: deviceID,
            target: target,
            mode: mode,
            size: size
        )
    }

    func close() async {}
}
