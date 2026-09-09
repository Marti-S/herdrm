import Foundation
import HerdrKit

protocol MobileTranscriptTransport: MobileTransport {
    func transcriptReads(paneID: String, lines: Int, fallbackInterval: Duration) -> AsyncThrowingStream<TerminalReadResult, Error>
}

extension SSHDirectTransport: MobileTranscriptTransport {
    func transcriptReads(paneID: String, lines: Int, fallbackInterval: Duration) -> AsyncThrowingStream<TerminalReadResult, Error> {
        ObservedTranscript.reads(
            fallbackInterval: fallbackInterval,
            open: {
                try await self.openTerminalSession(
                    target: .agent(paneID: paneID), mode: .observe,
                    size: TerminalSize(columns: 80, rows: 24)
                )
            },
            read: { try await self.readPaneTranscript(paneID: paneID, lines: lines) }
        )
    }
}

extension FleetBridgeDeviceTransport: MobileTranscriptTransport {
    func transcriptReads(paneID: String, lines: Int, fallbackInterval: Duration) -> AsyncThrowingStream<TerminalReadResult, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                var channel: FleetBridgeChannel?
                do {
                    let features = try await client.rpcSession.features(client: client, deviceID: deviceID)
                    if !features.transcript {
                        for try await read in ObservedTranscript.polling(interval: fallbackInterval, read: {
                            try await self.readPaneTranscript(paneID: paneID, lines: lines)
                        }) {
                            continuation.yield(read)
                        }
                        continuation.finish()
                        return
                    }
                    let opened = try await client.authenticatedChannel()
                    channel = opened.channel
                    let request = FleetBridgeRPCRequest(
                        deviceID: deviceID, method: FleetBridgePerformanceProtocol.transcriptMethod,
                        params: .object(["pane_id": .string(paneID), "lines": .number(Double(max(1, min(lines, 250))))])
                    )
                    try await withBridgeDeadline { try await opened.channel.send(.rpc(request)) }
                    var accumulator = TerminalTranscriptAccumulator()
                    while !Task.isCancelled, let record = try await opened.channel.receive(within: .seconds(45)) {
                        switch record {
                        case .rpc(let response) where response.id == request.id:
                            if case .bool(true)? = response.result["heartbeat"] { continue }
                            let update = try JSONDecoder().decode(TerminalTranscriptUpdate.self, from: JSONEncoder().encode(response.result))
                            continuation.yield(try accumulator.apply(update))
                        case .error(let error): throw FleetBridgeClient.serverError(error)
                        default: throw FleetBridgeClientError.unexpectedRecord("transcript update")
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
}
