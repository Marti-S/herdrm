import Foundation

/// Minimal full-duplex byte stream used by the fleet bridge protocol.
///
/// Implementations must preserve byte order. Reads may return arbitrary chunks;
/// writes must not interleave bytes from concurrent calls.
public protocol FleetBridgeByteStream: Sendable {
    func read(maximumBytes: Int) async throws -> Data?
    func write(_ data: Data) async throws
    func close() async
}

public enum FleetBridgeHostError: Error, LocalizedError, Sendable, Equatable {
    case incompatibleProtocol(received: Int, supported: Int)
    case expectedHello
    case unexpectedMessage
    case streamClosed

    public var errorDescription: String? {
        switch self {
        case .incompatibleProtocol(let received, let supported):
            return "Fleet protocol \(received) is incompatible; this host supports \(supported)."
        case .expectedHello:
            return "The first fleet bridge message must be a client hello."
        case .unexpectedMessage:
            return "The fleet bridge client sent a message that is not valid in this direction."
        case .streamClosed:
            return "The fleet bridge stream is closed."
        }
    }
}

/// Multiplexes paired clients over one host-owned fleet snapshot.
///
/// The Mac app remains authoritative for device sessions and supplies already
/// sanitized snapshots plus an allowlisted request handler.
public actor FleetBridgeHost {
    public typealias RequestHandler =
        @Sendable (FleetRPCRequest) async -> FleetRPCResponse

    public let bridgeID: UUID
    public let bridgeName: String
    public let capabilities: Set<FleetCapability>

    private var snapshot: FleetSnapshot
    private let requestHandler: RequestHandler
    private var connections: [UUID: FleetBridgeHostConnection] = [:]

    public init(
        bridgeID: UUID,
        bridgeName: String,
        capabilities: Set<FleetCapability>,
        initialSnapshot: FleetSnapshot,
        requestHandler: @escaping RequestHandler
    ) {
        self.bridgeID = bridgeID
        self.bridgeName = bridgeName
        self.capabilities = capabilities
        self.snapshot = initialSnapshot
        self.requestHandler = requestHandler
    }

    public var currentSnapshot: FleetSnapshot { snapshot }
    public var activeConnectionCount: Int { connections.count }

    /// Starts serving one authenticated byte stream.
    ///
    /// Authentication and endpoint reachability are owned by the carrier. The
    /// first implementation uses a 0600 Unix socket reached through pinned SSH.
    public func accept(_ stream: any FleetBridgeByteStream) {
        let id = UUID()
        let connection = FleetBridgeHostConnection(
            stream: stream,
            welcomeProvider: { [weak self] hello in
                guard let self else { throw FleetBridgeHostError.streamClosed }
                return try await self.welcome(for: hello)
            },
            requestHandler: { [weak self] request in
                guard let self else {
                    return .failure(
                        id: request.id,
                        error: FleetRPCError(
                            code: "bridge_stopped",
                            message: "The fleet bridge is stopping.",
                            retryable: true
                        )
                    )
                }
                return await self.handle(request)
            }
        )
        connections[id] = connection

        Task { [weak self] in
            await connection.run()
            await self?.removeConnection(id)
        }
    }

    /// Publishes a newer full snapshot to every handshaken client.
    ///
    /// Full snapshots keep protocol v1 deterministic. Revisions leave room for
    /// replay or delta compression without changing client resource identity.
    @discardableResult
    public func publish(
        _ newSnapshot: FleetSnapshot,
        reason: FleetSnapshotUpdate.Reason = .changed
    ) async -> Bool {
        guard newSnapshot.revision > snapshot.revision else { return false }
        snapshot = newSnapshot
        let update = FleetSnapshotUpdate(reason: reason, snapshot: newSnapshot)
        for connection in connections.values {
            await connection.publish(update)
        }
        return true
    }

    public func stop() async {
        let live = Array(connections.values)
        connections.removeAll()
        for connection in live {
            await connection.close()
        }
    }

    private func welcome(for hello: FleetClientHello) throws -> FleetServerWelcome {
        guard hello.protocolVersion == FleetBridgeProtocol.version else {
            throw FleetBridgeHostError.incompatibleProtocol(
                received: hello.protocolVersion,
                supported: FleetBridgeProtocol.version
            )
        }
        return FleetServerWelcome(
            bridgeID: bridgeID,
            bridgeName: bridgeName,
            capabilities: capabilities,
            snapshot: snapshot
        )
    }

    private func handle(_ request: FleetRPCRequest) async -> FleetRPCResponse {
        if let minimumRevision = request.minimumRevision,
           snapshot.revision < minimumRevision {
            return .failure(
                id: request.id,
                error: FleetRPCError(
                    code: "stale_revision",
                    message: "The host has fleet revision \(snapshot.revision), but the request requires \(minimumRevision).",
                    retryable: true
                )
            )
        }
        return await requestHandler(request)
    }

    private func removeConnection(_ id: UUID) {
        connections[id] = nil
    }
}

private actor FleetBridgeHostConnection {
    typealias WelcomeProvider =
        @Sendable (FleetClientHello) async throws -> FleetServerWelcome
    typealias RequestHandler = FleetBridgeHost.RequestHandler

    private struct PendingWrite {
        let data: Data
        let continuation: CheckedContinuation<Void, Error>
    }

    private let stream: any FleetBridgeByteStream
    private let welcomeProvider: WelcomeProvider
    private let requestHandler: RequestHandler
    private var decoder = FleetWireDecoder()
    private var ready = false
    private var closed = false
    private var writing = false
    private var writes: [PendingWrite] = []

    init(
        stream: any FleetBridgeByteStream,
        welcomeProvider: @escaping WelcomeProvider,
        requestHandler: @escaping RequestHandler
    ) {
        self.stream = stream
        self.welcomeProvider = welcomeProvider
        self.requestHandler = requestHandler
    }

    func run() async {
        do {
            try await runLoop()
        } catch {
            // The carrier owns diagnostics. A malformed or disconnected client
            // cannot affect other bridge connections.
        }
        await close()
    }

    func publish(_ update: FleetSnapshotUpdate) async {
        guard ready, !closed else { return }
        do {
            try await send(.snapshot(update))
        } catch {
            await close()
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        let pending = writes
        writes.removeAll()
        for write in pending {
            write.continuation.resume(throwing: FleetBridgeHostError.streamClosed)
        }
        await stream.close()
    }

    private func runLoop() async throws {
        guard let first = try await nextMessage() else {
            throw FleetBridgeHostError.streamClosed
        }
        guard case .hello(let hello) = first else {
            throw FleetBridgeHostError.expectedHello
        }

        let welcome = try await welcomeProvider(hello)
        try await send(.welcome(welcome))
        ready = true

        while let message = try await nextMessage() {
            switch message {
            case .request(let request):
                try await send(.response(await requestHandler(request)))
            case .ping:
                try await send(.pong)
            case .hello, .welcome, .snapshot, .response, .pong:
                throw FleetBridgeHostError.unexpectedMessage
            }
        }
    }

    private func nextMessage() async throws -> FleetWireMessage? {
        while true {
            if let message = try decoder.nextMessage() {
                return message
            }
            guard let chunk = try await stream.read(maximumBytes: 64 * 1024) else {
                return nil
            }
            guard !chunk.isEmpty else { continue }
            try decoder.append(chunk)
        }
    }

    private func send(_ message: FleetWireMessage) async throws {
        guard !closed else { throw FleetBridgeHostError.streamClosed }
        let data = try FleetWireCodec.encode(message)
        try await withCheckedThrowingContinuation { continuation in
            writes.append(PendingWrite(data: data, continuation: continuation))
            guard !writing else { return }
            writing = true
            Task { await drainWrites() }
        }
    }

    private func drainWrites() async {
        while !writes.isEmpty, !closed {
            let next = writes.removeFirst()
            do {
                try await stream.write(next.data)
                next.continuation.resume()
            } catch {
                next.continuation.resume(throwing: error)
                let remaining = writes
                writes.removeAll()
                for write in remaining {
                    write.continuation.resume(throwing: error)
                }
                writing = false
                closed = true
                await stream.close()
                return
            }
        }
        writing = false
    }
}
