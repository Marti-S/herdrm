#if canImport(Network)
import Foundation
import Network

public enum FleetTCPError: Error, LocalizedError, Sendable {
    case invalidHost
    case invalidPort
    case cancelled
    case connectionFailed(String)
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .invalidHost: return "the bridge host is empty"
        case .invalidPort: return "the bridge port is invalid"
        case .cancelled: return "the bridge connection was cancelled"
        case .connectionFailed(let detail): return "bridge connection failed: \(detail)"
        case .connectionClosed: return "the bridge closed the connection"
        }
    }
}

/// Small async byte-stream wrapper around `NWConnection`.
///
/// It deliberately knows nothing about fleet messages or terminal frames. The
/// shared framed protocol sits above this type, while Tailscale supplies private
/// reachability below it. That keeps the same transport usable by the iOS client
/// and the Mac listener, and makes a later TLS wrapper an isolated change.
public final class FleetTCPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let startLock = NSLock()
    private var didStart = false

    public convenience init(
        host: String,
        port: UInt16,
        queue: DispatchQueue? = nil
    ) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { throw FleetTCPError.invalidHost }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw FleetTCPError.invalidPort
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(trimmedHost),
            port: endpointPort,
            using: .tcp
        )
        self.init(
            connection: connection,
            queue: queue ?? DispatchQueue(label: "dev.bybee.herdrm.bridge.tcp.client")
        )
    }

    public convenience init(
        endpoint: FleetBridgeEndpoint,
        queue: DispatchQueue? = nil
    ) throws {
        guard endpoint.isValid else { throw FleetTCPError.invalidHost }
        try self.init(host: endpoint.host, port: endpoint.port, queue: queue)
    }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func start() async throws {
        let shouldStart = startLock.withLock { () -> Bool in
            guard !didStart else { return false }
            didStart = true
            return true
        }
        guard shouldStart else { return }

        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = FleetContinuationGate<Void>(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resume(returning: ())
                    case .failed(let error):
                        gate.resume(
                            throwing: FleetTCPError.connectionFailed(error.localizedDescription)
                        )
                    case .cancelled:
                        gate.resume(throwing: FleetTCPError.cancelled)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: FleetTCPError.connectionFailed(error.localizedDescription)
                        )
                    } else {
                        continuation.resume(returning: ())
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Returns the next available bytes, or nil after an orderly remote close.
    public func receive(maximumBytes: Int = 64 * 1024) async throws -> Data? {
        precondition(maximumBytes > 0)
        let connection = connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: maximumBytes
                ) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(
                            throwing: FleetTCPError.connectionFailed(error.localizedDescription)
                        )
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: FleetTCPError.connectionClosed)
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func close() {
        connection.cancel()
    }

    var underlyingConnection: NWConnection { connection }
}

private final class FleetContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: error)
    }
}
#endif