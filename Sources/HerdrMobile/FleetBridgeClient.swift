import Foundation
import HerdrKit
import Network

private final class FleetBridgeStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func succeed() { resume(.success(())) }
    func fail(_ error: any Error) { resume(.failure(error)) }
    private func resume(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

enum FleetBridgeClientError: LocalizedError {
    case invalidEndpoint
    case connectionFailed(String)
    case connectionClosed
    case timedOut
    case missingToken
    case invalidPairingToken
    case protocolMismatch(Int)
    case serverIdentityChanged(expected: UUID, received: UUID)
    case serverAuthenticationFailed
    case unexpectedRecord(String)
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return String(localized: "The Mac bridge address or port is invalid.")
        case .connectionFailed(let detail):
            return String(localized: "Could not connect to the Mac bridge: \(detail)")
        case .connectionClosed:
            return String(localized: "The Mac bridge closed the connection.")
        case .timedOut:
            return String(localized: "The Mac bridge did not respond in time.")
        case .missingToken:
            return String(localized: "No pairing token is saved for this Mac.")
        case .invalidPairingToken:
            return String(localized: "The saved pairing token is invalid. Remove and pair this Mac again.")
        case .protocolMismatch(let version):
            return String(localized: "The Mac uses bridge protocol \(version), but this app supports \(FleetBridgeProtocol.version).")
        case .serverIdentityChanged(let expected, let received):
            return String(localized: "The Mac identity changed from \(expected.uuidString) to \(received.uuidString). Remove and pair it again.")
        case .serverAuthenticationFailed:
            return String(localized: "The Mac could not prove its pairing identity. Remove and pair it again.")
        case .unexpectedRecord(let type):
            return String(localized: "The Mac bridge sent an unexpected \(type) record.")
        case .server(_, let message): return message
        }
    }

    var isPermanent: Bool {
        switch self {
        case .invalidEndpoint, .missingToken, .invalidPairingToken, .protocolMismatch,
             .serverIdentityChanged, .serverAuthenticationFailed: return true
        case .server(let code, _): return ["authentication_failed", "protocol_mismatch"].contains(code)
        case .connectionFailed, .connectionClosed, .timedOut, .unexpectedRecord: return false
        }
    }
}

func withBridgeDeadline<T: Sendable>(
    _ duration: Duration = .seconds(15),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw FleetBridgeClientError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Owns every connection, including terminal and transcript streams, so scene
/// suspension closes more than just the fleet subscription or the RPC channel.
actor FleetBridgeChannelRegistry {
    private var channels: [UUID: FleetBridgeChannel] = [:]
    private var closed = false
    func register(_ channel: FleetBridgeChannel) throws {
        guard !closed else { throw FleetBridgeClientError.connectionClosed }
        channels[channel.id] = channel
    }
    func remove(_ id: UUID) { channels.removeValue(forKey: id) }
    func close() async {
        closed = true
        let current = Array(channels.values)
        channels.removeAll()
        for channel in current { await channel.close() }
    }
}

/// One authenticated TCP connection. Exactly one task may receive records;
/// persistent RPC uses a separate dispatcher to correlate concurrent replies.
actor FleetBridgeChannel {
    nonisolated let id = UUID()
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let registry: FleetBridgeChannelRegistry
    private let writer: BoundedAsyncWriter
    private var decoder = FleetBridgeRecordDecoder()
    private var queuedRecords: [FleetBridgeServerRecord] = []
    private var queuedIndex = 0
    private var started = false
    private var closed = false

    init(host: String, port: UInt16, registry: FleetBridgeChannelRegistry) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw FleetBridgeClientError.invalidEndpoint
        }
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let connection = NWConnection(host: NWEndpoint.Host(trimmed), port: endpointPort, using: parameters)
        self.connection = connection
        writer = BoundedAsyncWriter(maximumBytes: FleetBridgeProtocol.maximumRecordBytes) { data in
            try await withBridgeDeadline(.seconds(30)) {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        connection.send(content: data, completion: .contentProcessed { error in
                            if let error {
                                continuation.resume(throwing: FleetBridgeClientError.connectionFailed(error.localizedDescription))
                            } else { continuation.resume() }
                        })
                    }
                } onCancel: { connection.cancel() }
            }
        }
        queue = DispatchQueue(label: "dev.bybee.herdrm.ios.fleet-bridge.\(UUID().uuidString)")
        self.registry = registry
    }

    func start() async throws {
        guard !started else { return }
        guard !closed else { throw FleetBridgeClientError.connectionClosed }
        started = true
        let connection = connection
        let queue = queue
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = FleetBridgeStartGate(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.succeed()
                    case .failed(let error): gate.fail(FleetBridgeClientError.connectionFailed(error.localizedDescription))
                    case .cancelled: gate.fail(FleetBridgeClientError.connectionClosed)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 15) { gate.fail(FleetBridgeClientError.timedOut) }
            }
        } onCancel: { connection.cancel() }
    }

    func send(_ record: FleetBridgeClientRecord) async throws {
        guard started, !closed else { throw FleetBridgeClientError.connectionClosed }
        let data = try FleetBridgeWire.encodeClient(record)
        // Cancelling one RPC removes a queued send but cannot retract bytes
        // already handed to Network.framework or cancel unrelated requests.
        try await writer.send(data)
    }

    func receive() async throws -> FleetBridgeServerRecord? {
        guard started, !closed else { return nil }
        while queuedIndex == queuedRecords.count {
            queuedRecords.removeAll(keepingCapacity: true)
            queuedIndex = 0
            guard let chunk = try await receiveChunk() else { await close(); return nil }
            if chunk.isEmpty { continue }
            try decoder.append(chunk)
            while let line = try decoder.nextRecordData() {
                queuedRecords.append(try FleetBridgeWire.decodeServer(line))
            }
        }
        let record = queuedRecords[queuedIndex]
        queuedIndex += 1
        return record
    }

    func receive(within duration: Duration) async throws -> FleetBridgeServerRecord? {
        try await withBridgeDeadline(duration) { try await self.receive() }
    }

    func close() async {
        if !closed {
            closed = true
            connection.cancel()
            queuedRecords.removeAll()
            queuedIndex = 0
        }
        await writer.close()
        await registry.remove(id)
    }

    private func receiveChunk() async throws -> Data? {
        let connection = connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                    if let error {
                        continuation.resume(throwing: FleetBridgeClientError.connectionFailed(error.localizedDescription))
                    } else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(returning: complete ? nil : Data()) }
                }
            }
        } onCancel: { connection.cancel() }
    }
}

/// Shared by all device views of a paired Mac. Control RPC is persistent after
/// explicit capability negotiation; bulk streams use independent connections.
final class FleetBridgeClient: Sendable {
    let bridge: MobileBridge
    let token: String
    let clientID: UUID
    let clientName: String
    let rpcSession = FleetBridgeRPCSession()
    private let channels = FleetBridgeChannelRegistry()

    init(bridge: MobileBridge, token: String, clientID: UUID, clientName: String) {
        self.bridge = bridge
        self.token = token
        self.clientID = clientID
        self.clientName = clientName
    }

    func close() async {
        await channels.close()
        await rpcSession.close()
    }

    func snapshot() async throws -> FleetSnapshot {
        let (channel, _) = try await authenticatedChannel()
        do {
            let result: FleetSnapshot = try await withBridgeDeadline {
                let request = FleetBridgeSnapshotRequest()
                try await channel.send(.snapshot(request))
                while let record = try await channel.receive() {
                    switch record {
                    case .snapshot(let response) where response.requestID == request.id: return response.snapshot
                    case .error(let error): throw Self.serverError(error)
                    default: throw FleetBridgeClientError.unexpectedRecord("snapshot response")
                    }
                }
                throw FleetBridgeClientError.connectionClosed
            }
            await channel.close()
            return result
        } catch { await channel.close(); throw error }
    }

    func snapshots(after revision: UInt64?) -> AsyncThrowingStream<FleetSnapshot, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                var channel: FleetBridgeChannel?
                do {
                    let opened = try await authenticatedChannel()
                    channel = opened.channel
                    let request = FleetBridgeSubscribeRequest(afterRevision: revision)
                    try await opened.channel.send(.subscribe(request))
                    var checkedCapabilities = false
                    var receiveDeadline: Duration? = .seconds(15)
                    while !Task.isCancelled {
                        let record: FleetBridgeServerRecord?
                        if let receiveDeadline {
                            record = try await opened.channel.receive(within: receiveDeadline)
                        } else {
                            record = try await opened.channel.receive()
                        }
                        guard let record else { break }
                        switch record {
                        case .snapshot(let response) where response.requestID == request.id:
                            continuation.yield(response.snapshot)
                            if !checkedCapabilities {
                                checkedCapabilities = true
                                receiveDeadline = nil
                                if let device = response.snapshot.devices.first {
                                    let features = try await rpcSession.features(client: self, deviceID: device.id)
                                    if features.persistentRPC { receiveDeadline = .seconds(45) }
                                }
                            }
                        case .rpc(let response) where response.id == request.id:
                            guard case .bool(true)? = response.result["heartbeat"] else {
                                throw FleetBridgeClientError.unexpectedRecord("fleet heartbeat")
                            }
                            receiveDeadline = .seconds(45)
                        case .error(let error): throw Self.serverError(error)
                        default: throw FleetBridgeClientError.unexpectedRecord("fleet subscription")
                        }
                    }
                    if !Task.isCancelled { throw FleetBridgeClientError.connectionClosed }
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() }
                    else { continuation.finish(throwing: error) }
                }
                if let channel { await channel.close() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func request(deviceID: UUID, method: String, params: JSONValue) async throws -> JSONValue {
        let interval = PerformanceInterval("BridgeRPC")
        defer { interval.end() }
        return try await rpcSession.request(client: self, deviceID: deviceID, method: method, params: params)
    }

    /// Compatibility path for hosts that explicitly reject bridge.capabilities.
    func requestOnce(deviceID: UUID, method: String, params: JSONValue) async throws -> JSONValue {
        let (channel, _) = try await authenticatedChannel()
        do {
            let result: JSONValue = try await withBridgeDeadline {
                let request = FleetBridgeRPCRequest(deviceID: deviceID, method: method, params: params)
                try await channel.send(.rpc(request))
                while let record = try await channel.receive() {
                    switch record {
                    case .rpc(let response) where response.id == request.id: return response.result
                    case .error(let error): throw Self.serverError(error)
                    default: throw FleetBridgeClientError.unexpectedRecord("RPC response")
                    }
                }
                throw FleetBridgeClientError.connectionClosed
            }
            await channel.close()
            return result
        } catch { await channel.close(); throw error }
    }

    func openTerminalSession(
        deviceID: UUID, target: TerminalAttachTarget, mode: TerminalSessionMode, size: TerminalSize
    ) async throws -> any TerminalSession {
        guard size.isValid else { throw TerminalSessionError.invalidSize }
        let (channel, _) = try await authenticatedChannel()
        do {
            let request = FleetBridgeTerminalOpenRequest(
                deviceID: deviceID, target: FleetTerminalTarget(target), mode: mode, size: size
            )
            try await withBridgeDeadline { try await channel.send(.terminalOpen(request)) }
            return FleetBridgeTerminalSession(channel: channel, streamID: request.streamID, mode: mode, initialSize: size)
        } catch { await channel.close(); throw error }
    }

    func authenticatedChannel() async throws -> (channel: FleetBridgeChannel, welcome: FleetBridgeWelcome) {
        let interval = PerformanceInterval("BridgeAuthentication")
        defer { interval.end() }
        guard !token.isEmpty else { throw FleetBridgeClientError.missingToken }
        let channel = try FleetBridgeChannel(host: bridge.host, port: bridge.port, registry: channels)
        do {
            try await channels.register(channel)
            return try await withBridgeDeadline {
                try await channel.start()
                let clientNonce = try FleetBridgeAuthenticator.randomNonce()
                try await channel.send(.hello(FleetBridgeHello(
                    clientID: self.clientID, clientName: self.clientName, clientNonce: clientNonce
                )))
                guard let challengeRecord = try await channel.receive() else { throw FleetBridgeClientError.connectionClosed }
                let challenge: FleetBridgeChallenge
                switch challengeRecord {
                case .challenge(let value): challenge = value
                case .error(let error): throw Self.serverError(error)
                default: throw FleetBridgeClientError.unexpectedRecord("handshake challenge")
                }
                guard challenge.protocolVersion == FleetBridgeProtocol.version else {
                    throw FleetBridgeClientError.protocolMismatch(challenge.protocolVersion)
                }
                if let expected = self.bridge.expectedServerID, challenge.serverID != expected {
                    throw FleetBridgeClientError.serverIdentityChanged(expected: expected, received: challenge.serverID)
                }
                let expectedServerProof = try FleetBridgeAuthenticator.serverProof(
                    token: self.token, clientID: self.clientID, clientName: self.clientName,
                    serverID: challenge.serverID, clientNonce: clientNonce, serverNonce: challenge.serverNonce
                )
                guard FleetBridgeAuthenticator.verify(challenge.serverProof, equals: expectedServerProof) else {
                    throw FleetBridgeClientError.serverAuthenticationFailed
                }
                let clientProof = try FleetBridgeAuthenticator.clientProof(
                    token: self.token, clientID: self.clientID, clientName: self.clientName,
                    serverID: challenge.serverID, clientNonce: clientNonce, serverNonce: challenge.serverNonce
                )
                try await channel.send(.authenticate(FleetBridgeAuthentication(clientProof: clientProof)))
                guard let welcomeRecord = try await channel.receive() else { throw FleetBridgeClientError.connectionClosed }
                switch welcomeRecord {
                case .welcome(let welcome):
                    guard welcome.protocolVersion == FleetBridgeProtocol.version else {
                        throw FleetBridgeClientError.protocolMismatch(welcome.protocolVersion)
                    }
                    guard welcome.serverID == challenge.serverID else {
                        throw FleetBridgeClientError.serverIdentityChanged(expected: challenge.serverID, received: welcome.serverID)
                    }
                    return (channel, welcome)
                case .error(let error): throw Self.serverError(error)
                default: throw FleetBridgeClientError.unexpectedRecord("handshake welcome")
                }
            }
        } catch let error as FleetBridgeAuthenticationError {
            await channel.close()
            switch error {
            case .invalidToken: throw FleetBridgeClientError.invalidPairingToken
            case .invalidNonceLength, .randomFailure: throw FleetBridgeClientError.serverAuthenticationFailed
            }
        } catch { await channel.close(); throw error }
    }

    static func serverError(_ error: FleetBridgeErrorRecord) -> FleetBridgeClientError {
        .server(code: error.code, message: error.message)
    }
}

private actor FleetBridgeTerminalSession: TerminalSession {
    nonisolated let mode: TerminalSessionMode
    private let channel: FleetBridgeChannel
    private let streamID: UUID
    private var size: TerminalSize
    private var closed = false
    init(channel: FleetBridgeChannel, streamID: UUID, mode: TerminalSessionMode, initialSize: TerminalSize) {
        self.channel = channel; self.streamID = streamID; self.mode = mode; size = initialSize
    }
    func read() async throws -> TerminalFrame? {
        guard !closed else { return nil }
        while let record = try await channel.receive() {
            switch record {
            case .terminalFrame(let value) where value.streamID == streamID: return value.frame
            case .terminalClosed(let value) where value.streamID == streamID:
                closed = true; await channel.close(); return nil
            case .error(let error) where error.streamID == nil || error.streamID == streamID:
                closed = true; await channel.close(); throw FleetBridgeClient.serverError(error)
            default: continue
            }
        }
        closed = true
        throw FleetBridgeClientError.connectionClosed
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw TerminalSessionError.closed }
        guard mode.allowsInput else { throw TerminalSessionError.readOnly }
        guard !data.isEmpty else { return }
        try await channel.send(.terminalInput(FleetBridgeTerminalInput(streamID: streamID, bytes: data)))
    }
    func resize(_ size: TerminalSize) async throws {
        guard !closed else { throw TerminalSessionError.closed }
        guard mode.allowsResize else { throw TerminalSessionError.readOnly }
        guard size.isValid else { throw TerminalSessionError.invalidSize }
        guard size != self.size else { return }
        try await channel.send(.terminalResize(FleetBridgeTerminalResize(streamID: streamID, size: size)))
        self.size = size
    }
    func close() async {
        guard !closed else { return }
        closed = true
        if mode.access == .control {
            let channel = channel
            let streamID = streamID
            try? await withBridgeDeadline(.seconds(2)) {
                try await channel.send(.terminalRelease(FleetBridgeTerminalRelease(streamID: streamID)))
            }
        }
        await channel.close()
    }
}

struct FleetBridgeDeviceTransport: MobileTransport {
    let client: FleetBridgeClient
    let deviceID: UUID
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        try await client.request(deviceID: deviceID, method: method, params: params)
    }
    func events(kinds: [String]) -> AsyncThrowingStream<HerdrEvent, Error> {
        // The fleet and transcript subscriptions are separately owned.
        AsyncThrowingStream { $0.finish() }
    }
    func openTerminalSession(target: TerminalAttachTarget, mode: TerminalSessionMode, size: TerminalSize) async throws -> any TerminalSession {
        try await client.openTerminalSession(deviceID: deviceID, target: target, mode: mode, size: size)
    }
    func close() async {}
}
