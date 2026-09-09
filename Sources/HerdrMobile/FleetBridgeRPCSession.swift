import Foundation
import HerdrKit

/// Capabilities are negotiated inside the authenticated v2 protocol. Old peers
/// explicitly rejecting discovery keep their one-operation-per-connection wire.
actor FleetBridgeRPCSession {
    struct Features: Sendable {
        let persistentRPC: Bool
        let transcript: Bool
        static let legacy = Features(persistentRPC: false, transcript: false)
    }
    private struct Prepared: Sendable {
        let channel: FleetBridgeChannel?
        let features: Features
        let requests: RequestMultiplexer<JSONValue>
    }
    private struct Opening {
        let id: UUID
        let task: Task<Prepared, Error>
    }
    private var prepared: Prepared?
    private var opening: Opening?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var closed = false
    private var admitted = 0

    func features(client: FleetBridgeClient, deviceID: UUID) async throws -> Features {
        try await prepare(client: client, deviceID: deviceID).features
    }

    func request(client: FleetBridgeClient, deviceID: UUID, method: String, params: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !closed else { throw FleetBridgeClientError.connectionClosed }
        guard admitted < FleetBridgePerformanceProtocol.maximumInFlightRequests else {
            throw RequestMultiplexer<JSONValue>.Failure.overloaded
        }
        admitted += 1
        defer { admitted -= 1 }
        let connection = try await prepare(client: client, deviceID: deviceID)
        try Task.checkCancellation()
        guard !closed else { throw FleetBridgeClientError.connectionClosed }
        guard let channel = connection.channel else {
            return try await client.requestOnce(deviceID: deviceID, method: method, params: params)
        }
        guard prepared?.channel?.id == channel.id else { throw FleetBridgeClientError.connectionClosed }
        return try await perform(
            FleetBridgeRPCRequest(deviceID: deviceID, method: method, params: params), on: connection
        )
    }

    func close() async {
        closed = true
        let openingTask = opening?.task
        opening = nil
        openingTask?.cancel()
        if let current = prepared { await fail(current, error: FleetBridgeClientError.connectionClosed) }
        if let value = try? await openingTask?.value { await value.channel?.close() }
    }

    private func prepare(client: FleetBridgeClient, deviceID: UUID) async throws -> Prepared {
        guard !closed else { throw FleetBridgeClientError.connectionClosed }
        if let prepared { return prepared }
        let attempt: Opening
        if let opening {
            attempt = opening
        } else {
            let id = UUID()
            let task = Task { () throws -> Prepared in
                let (channel, _) = try await client.authenticatedChannel()
                do {
                    let result: Prepared = try await withBridgeDeadline {
                        // Older hosts validate the device before method dispatch.
                        // Use a real fleet device, not the separate pairing server ID.
                        let request = FleetBridgeRPCRequest(
                            deviceID: deviceID,
                            method: FleetBridgePerformanceProtocol.capabilitiesMethod
                        )
                        try await channel.send(.rpc(request))
                        guard let record = try await channel.receive() else { throw FleetBridgeClientError.connectionClosed }
                        switch record {
                        case .rpc(let response) where response.id == request.id:
                            guard case .bool(true)? = response.result["persistent_rpc"] else {
                                throw FleetBridgeClientError.unexpectedRecord("capabilities")
                            }
                            let transcript: Bool
                            if case .bool(true)? = response.result["pane_transcript"] { transcript = true }
                            else { transcript = false }
                            return Prepared(
                                channel: channel,
                                features: Features(persistentRPC: true, transcript: transcript),
                                requests: RequestMultiplexer()
                            )
                        case .error(let error) where error.code == "unsupported_method":
                            await channel.close()
                            return Prepared(channel: nil, features: .legacy, requests: RequestMultiplexer())
                        case .error(let error): throw FleetBridgeClient.serverError(error)
                        default: throw FleetBridgeClientError.unexpectedRecord("capabilities response")
                        }
                    }
                    return result
                } catch { await channel.close(); throw error }
            }
            attempt = Opening(id: id, task: task)
            opening = attempt
        }
        do {
            let value = try await attempt.task.value
            guard !closed else { await value.channel?.close(); throw FleetBridgeClientError.connectionClosed }
            if opening?.id == attempt.id {
                opening = nil
                prepared = value
                if let channel = value.channel { startReader(value, channel: channel) }
            }
            guard let current = prepared,
                  current.channel?.id == value.channel?.id else {
                throw FleetBridgeClientError.connectionClosed
            }
            return current
        } catch {
            if opening?.id == attempt.id { opening = nil }
            throw error
        }
    }

    private func startReader(_ current: Prepared, channel: FleetBridgeChannel) {
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled, let record = try await channel.receive() {
                    switch record {
                    case .rpc(let response):
                        await current.requests.resolve(id: response.id, result: .success(response.result))
                    case .error(let error):
                        if error.fatal { throw FleetBridgeClient.serverError(error) }
                        guard let id = error.requestID else { throw FleetBridgeClient.serverError(error) }
                        await current.requests.resolve(id: id, result: .failure(FleetBridgeClient.serverError(error)))
                    default: throw FleetBridgeClientError.unexpectedRecord("persistent RPC")
                    }
                }
                if !Task.isCancelled { throw FleetBridgeClientError.connectionClosed }
            } catch { await self?.fail(current, error: error) }
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self else { return }
                guard await self.isCurrent(channel.id) else { return }
                // Busy requests already have deadlines; do not consume their
                // last admission slot for an idle heartbeat.
                if await current.requests.count == 0 {
                    do {
                        _ = try await self.perform(
                            FleetBridgeRPCRequest(deviceID: UUID(), method: FleetBridgePerformanceProtocol.pingMethod),
                            on: current
                        )
                    } catch { await self.fail(current, error: error); return }
                }
            }
        }
    }

    private func isCurrent(_ id: UUID) -> Bool { !closed && prepared?.channel?.id == id }

    private func perform(_ request: FleetBridgeRPCRequest, on current: Prepared) async throws -> JSONValue {
        guard let channel = current.channel, isCurrent(channel.id) else {
            throw FleetBridgeClientError.connectionClosed
        }
        do {
            return try await current.requests.perform(id: request.id) {
                try await channel.send(.rpc(request))
            }
        } catch is CancellationError {
            // The request may already have executed. Cancel only its waiter.
            throw CancellationError()
        } catch {
            if error as? RequestMultiplexer<JSONValue>.Failure == .timedOut {
                await fail(current, error: FleetBridgeClientError.timedOut)
            }
            throw error
        }
    }

    private func fail(_ current: Prepared, error: any Error) async {
        guard prepared?.channel?.id == current.channel?.id else { return }
        prepared = nil
        reader?.cancel()
        heartbeat?.cancel()
        reader = nil
        heartbeat = nil
        await current.requests.close(throwing: error)
        await current.channel?.close()
    }
}
