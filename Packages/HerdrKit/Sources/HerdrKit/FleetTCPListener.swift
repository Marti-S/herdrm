#if canImport(Network)
import Foundation
import Network

/// Tailscale-ready TCP listener. Configure `bindHost` as `127.0.0.1` when a
/// `tailscale serve --tcp` forwarder publishes the bridge, or nil when the app
/// is intentionally listening on the Mac's interfaces and access is restricted
/// by the tailnet ACL/firewall.
public final class FleetTCPListener: @unchecked Sendable {
    public typealias ConnectionHandler = @Sendable (FleetTCPConnection) async -> Void

    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var didStart = false

    public init(
        port: UInt16,
        bindHost: String? = "127.0.0.1",
        queue: DispatchQueue? = nil
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw FleetTCPError.invalidPort
        }
        let parameters = NWParameters.tcp
        if let bindHost {
            let trimmed = bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw FleetTCPError.invalidHost }
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(trimmed),
                port: nwPort
            )
        }
        self.listener = try NWListener(using: parameters, on: nwPort)
        self.queue = queue
            ?? DispatchQueue(label: "dev.bybee.herdrm.bridge.tcp.listener")
    }

    /// Starts accepting connections and returns the bound port once the kernel
    /// reports the listener ready.
    @discardableResult
    public func start(handler: @escaping ConnectionHandler) async throws -> UInt16 {
        let shouldStart = lock.withLock { () -> Bool in
            guard !didStart else { return false }
            didStart = true
            return true
        }
        guard shouldStart else {
            guard let port = listener.port?.rawValue else {
                throw FleetTCPError.connectionClosed
            }
            return port
        }

        let listener = listener
        let queue = queue
        listener.newConnectionHandler = { connection in
            let stream = FleetTCPConnection(
                connection: connection,
                queue: DispatchQueue(
                    label: "dev.bybee.herdrm.bridge.tcp.connection.\(UUID().uuidString)"
                )
            )
            Task { await handler(stream) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = FleetContinuationValueGate<UInt16>(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue {
                            gate.resume(returning: port)
                        } else {
                            gate.resume(throwing: FleetTCPError.invalidPort)
                        }
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
                listener.start(queue: queue)
            }
        } onCancel: {
            listener.cancel()
        }
    }

    public func close() {
        listener.cancel()
    }

    public var boundPort: UInt16? {
        listener.port?.rawValue
    }
}

private final class FleetContinuationValueGate<Value>: @unchecked Sendable {
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