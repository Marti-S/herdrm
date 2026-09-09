import Foundation
import HerdrKit
import Network

private enum FleetBridgeWriteError: LocalizedError {
    case timedOut
    var errorDescription: String? { "The mobile client stopped accepting bridge output." }
}

/// Parsing and serialization never run on the Mac's main actor. One bounded
/// writer owns Network.framework sends and waits for actual stack processing.
actor FleetBridgeConnectionIO {
    private let connection: NWConnection
    private let writer: BoundedAsyncWriter
    private var decoder = FleetBridgeRecordDecoder()

    init(connection: NWConnection) {
        self.connection = connection
        writer = BoundedAsyncWriter(maximumBytes: FleetBridgeProtocol.maximumRecordBytes) { data in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            connection.send(content: data, completion: .contentProcessed { error in
                                if let error { continuation.resume(throwing: error) }
                                else { continuation.resume() }
                            })
                        }
                    } onCancel: { connection.cancel() }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw FleetBridgeWriteError.timedOut
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
    }

    func consume(_ data: Data) throws -> [FleetBridgeClientRecord] {
        try decoder.append(data)
        var records: [FleetBridgeClientRecord] = []
        while let line = try decoder.nextRecordData() { records.append(try FleetBridgeWire.decodeClient(line)) }
        return records
    }

    func send(_ record: FleetBridgeServerRecord) async throws {
        let interval = PerformanceInterval("BridgeEncodeAndWrite")
        var byteCount = 0
        defer { interval.end(bytes: byteCount) }
        let data = try FleetBridgeWire.encodeServer(record)
        byteCount = data.count
        try await writer.send(data)
    }

    func sendSnapshot(requestID: UUID, encodedSnapshot: Data) async throws {
        try await writer.send(FleetBridgeWire.encodeSnapshot(requestID: requestID, encodedSnapshot: encodedSnapshot))
    }

    func sendEncoded(_ data: Data) async throws { try await writer.send(data) }

    func close() async {
        connection.cancel()
        await writer.close()
    }
}
