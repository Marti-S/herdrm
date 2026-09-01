import Foundation

/// Versioned, newline-delimited protocol used between HerdrM on the Mac and a
/// paired mobile client. Each TCP connection performs a mutual challenge-
/// response handshake and then owns exactly one operation: snapshot,
/// subscription, RPC, or terminal stream.
public enum FleetBridgeProtocol {
    public static let version = 2
    public static let defaultPort: UInt16 = 45_983
    public static let maximumRecordBytes = 64 * 1024 * 1024
}

/// The client starts authentication with a fresh nonce. The pairing secret is
/// deliberately absent and never crosses the network after initial pairing.
public struct FleetBridgeHello: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let clientID: UUID
    public let clientName: String
    public let clientNonce: Data

    public init(
        protocolVersion: Int = FleetBridgeProtocol.version,
        clientID: UUID,
        clientName: String,
        clientNonce: Data
    ) {
        self.protocolVersion = protocolVersion
        self.clientID = clientID
        self.clientName = clientName
        self.clientNonce = clientNonce
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case clientID = "client_id"
        case clientName = "client_name"
        case clientNonce = "client_nonce"
    }
}

/// The server proves possession of the pairing secret before the client sends
/// its own proof. The proof binds both nonces and both stable endpoint IDs.
public struct FleetBridgeChallenge: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let serverID: UUID
    public let serverName: String
    public let serverNonce: Data
    public let serverProof: Data

    public init(
        protocolVersion: Int = FleetBridgeProtocol.version,
        serverID: UUID,
        serverName: String,
        serverNonce: Data,
        serverProof: Data
    ) {
        self.protocolVersion = protocolVersion
        self.serverID = serverID
        self.serverName = serverName
        self.serverNonce = serverNonce
        self.serverProof = serverProof
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case serverID = "server_id"
        case serverName = "server_name"
        case serverNonce = "server_nonce"
        case serverProof = "server_proof"
    }
}

public struct FleetBridgeAuthentication: Codable, Equatable, Sendable {
    public let clientProof: Data

    public init(clientProof: Data) {
        self.clientProof = clientProof
    }

    enum CodingKeys: String, CodingKey {
        case clientProof = "client_proof"
    }
}

public struct FleetBridgeWelcome: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let serverID: UUID
    public let serverName: String
    public let revision: UInt64

    public init(
        protocolVersion: Int = FleetBridgeProtocol.version,
        serverID: UUID,
        serverName: String,
        revision: UInt64
    ) {
        self.protocolVersion = protocolVersion
        self.serverID = serverID
        self.serverName = serverName
        self.revision = revision
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case serverID = "server_id"
        case serverName = "server_name"
        case revision
    }
}

public struct FleetBridgeSnapshotRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

public struct FleetBridgeSubscribeRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let afterRevision: UInt64?

    public init(id: UUID = UUID(), afterRevision: UInt64? = nil) {
        self.id = id
        self.afterRevision = afterRevision
    }

    enum CodingKeys: String, CodingKey {
        case id
        case afterRevision = "after_revision"
    }
}

public struct FleetBridgeRPCRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let deviceID: UUID
    public let method: String
    public let params: JSONValue

    public init(
        id: UUID = UUID(),
        deviceID: UUID,
        method: String,
        params: JSONValue = .object([:])
    ) {
        self.id = id
        self.deviceID = deviceID
        self.method = method
        self.params = params
    }

    enum CodingKeys: String, CodingKey {
        case id
        case deviceID = "device_id"
        case method
        case params
    }
}

public struct FleetBridgeRPCResponse: Codable, Equatable, Sendable {
    public let id: UUID
    public let result: JSONValue

    public init(id: UUID, result: JSONValue) {
        self.id = id
        self.result = result
    }
}

public struct FleetBridgeSnapshotRecord: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let snapshot: FleetSnapshot

    public init(requestID: UUID, snapshot: FleetSnapshot) {
        self.requestID = requestID
        self.snapshot = snapshot
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case snapshot
    }
}

public struct FleetBridgeTerminalOpenRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let streamID: UUID
    public let deviceID: UUID
    public let target: FleetTerminalTarget
    public let mode: TerminalSessionMode
    public let size: TerminalSize

    public init(
        id: UUID = UUID(),
        streamID: UUID = UUID(),
        deviceID: UUID,
        target: FleetTerminalTarget,
        mode: TerminalSessionMode,
        size: TerminalSize
    ) {
        self.id = id
        self.streamID = streamID
        self.deviceID = deviceID
        self.target = target
        self.mode = mode
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case id
        case streamID = "stream_id"
        case deviceID = "device_id"
        case target
        case mode
        case size
    }
}

public struct FleetBridgeTerminalInput: Codable, Equatable, Sendable {
    public let streamID: UUID
    public let bytes: Data

    public init(streamID: UUID, bytes: Data) {
        self.streamID = streamID
        self.bytes = bytes
    }

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case bytes
    }
}

public struct FleetBridgeTerminalResize: Codable, Equatable, Sendable {
    public let streamID: UUID
    public let size: TerminalSize

    public init(streamID: UUID, size: TerminalSize) {
        self.streamID = streamID
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case size
    }
}

public struct FleetBridgeTerminalRelease: Codable, Equatable, Sendable {
    public let streamID: UUID
    public init(streamID: UUID) { self.streamID = streamID }

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
    }
}

public struct FleetBridgeTerminalFrameRecord: Codable, Equatable, Sendable {
    public let streamID: UUID
    public let frame: TerminalFrame

    public init(streamID: UUID, frame: TerminalFrame) {
        self.streamID = streamID
        self.frame = frame
    }

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case frame
    }
}

public struct FleetBridgeTerminalClosedRecord: Codable, Equatable, Sendable {
    public let streamID: UUID
    public let reason: String?

    public init(streamID: UUID, reason: String?) {
        self.streamID = streamID
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case reason
    }
}

public struct FleetBridgeErrorRecord: Codable, Equatable, Sendable {
    public let requestID: UUID?
    public let streamID: UUID?
    public let code: String
    public let message: String
    public let fatal: Bool

    public init(
        requestID: UUID? = nil,
        streamID: UUID? = nil,
        code: String,
        message: String,
        fatal: Bool = false
    ) {
        self.requestID = requestID
        self.streamID = streamID
        self.code = code
        self.message = message
        self.fatal = fatal
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case streamID = "stream_id"
        case code
        case message
        case fatal
    }
}

public enum FleetBridgeClientRecord: Equatable, Sendable {
    case hello(FleetBridgeHello)
    case authenticate(FleetBridgeAuthentication)
    case snapshot(FleetBridgeSnapshotRequest)
    case subscribe(FleetBridgeSubscribeRequest)
    case rpc(FleetBridgeRPCRequest)
    case terminalOpen(FleetBridgeTerminalOpenRequest)
    case terminalInput(FleetBridgeTerminalInput)
    case terminalResize(FleetBridgeTerminalResize)
    case terminalRelease(FleetBridgeTerminalRelease)
}

public enum FleetBridgeServerRecord: Equatable, Sendable {
    case challenge(FleetBridgeChallenge)
    case welcome(FleetBridgeWelcome)
    case snapshot(FleetBridgeSnapshotRecord)
    case rpc(FleetBridgeRPCResponse)
    case terminalFrame(FleetBridgeTerminalFrameRecord)
    case terminalClosed(FleetBridgeTerminalClosedRecord)
    case error(FleetBridgeErrorRecord)
}

public enum FleetBridgeWireError: Error, LocalizedError, Sendable, Equatable {
    case emptyRecord
    case invalidRecord(String)
    case unsupportedRecordType(String)
    case recordTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyRecord:
            return "The bridge emitted an empty record."
        case .invalidRecord(let detail):
            return "The bridge emitted an invalid record: \(detail)"
        case .unsupportedRecordType(let type):
            return "The bridge emitted unsupported record type \(type)."
        case .recordTooLarge(let limit):
            return "The bridge record exceeded \(limit) bytes."
        }
    }
}

public enum FleetBridgeWire {
    public static func encodeClient(_ record: FleetBridgeClientRecord) throws -> Data {
        switch record {
        case .hello(let value): return try line(type: "bridge.hello", payload: value)
        case .authenticate(let value): return try line(type: "bridge.authenticate", payload: value)
        case .snapshot(let value): return try line(type: "fleet.snapshot", payload: value)
        case .subscribe(let value): return try line(type: "fleet.subscribe", payload: value)
        case .rpc(let value): return try line(type: "herdr.request", payload: value)
        case .terminalOpen(let value): return try line(type: "terminal.open", payload: value)
        case .terminalInput(let value): return try line(type: "terminal.input", payload: value)
        case .terminalResize(let value): return try line(type: "terminal.resize", payload: value)
        case .terminalRelease(let value): return try line(type: "terminal.release", payload: value)
        }
    }

    public static func decodeClient(_ data: Data) throws -> FleetBridgeClientRecord {
        let envelope = try decodeEnvelope(data)
        switch envelope.type {
        case "bridge.hello": return .hello(try decode(FleetBridgeHello.self, payload: envelope.payload))
        case "bridge.authenticate": return .authenticate(try decode(FleetBridgeAuthentication.self, payload: envelope.payload))
        case "fleet.snapshot": return .snapshot(try decode(FleetBridgeSnapshotRequest.self, payload: envelope.payload))
        case "fleet.subscribe": return .subscribe(try decode(FleetBridgeSubscribeRequest.self, payload: envelope.payload))
        case "herdr.request": return .rpc(try decode(FleetBridgeRPCRequest.self, payload: envelope.payload))
        case "terminal.open": return .terminalOpen(try decode(FleetBridgeTerminalOpenRequest.self, payload: envelope.payload))
        case "terminal.input": return .terminalInput(try decode(FleetBridgeTerminalInput.self, payload: envelope.payload))
        case "terminal.resize": return .terminalResize(try decode(FleetBridgeTerminalResize.self, payload: envelope.payload))
        case "terminal.release": return .terminalRelease(try decode(FleetBridgeTerminalRelease.self, payload: envelope.payload))
        default: throw FleetBridgeWireError.unsupportedRecordType(envelope.type)
        }
    }

    public static func encodeServer(_ record: FleetBridgeServerRecord) throws -> Data {
        switch record {
        case .challenge(let value): return try line(type: "bridge.challenge", payload: value)
        case .welcome(let value): return try line(type: "bridge.welcome", payload: value)
        case .snapshot(let value): return try line(type: "fleet.snapshot", payload: value)
        case .rpc(let value): return try line(type: "herdr.response", payload: value)
        case .terminalFrame(let value): return try line(type: "terminal.frame", payload: value)
        case .terminalClosed(let value): return try line(type: "terminal.closed", payload: value)
        case .error(let value): return try line(type: "bridge.error", payload: value)
        }
    }

    /// Wraps a cached JSON-encoded fleet snapshot in the subscriber-specific
    /// response envelope. The snapshot payload can therefore be constructed and
    /// encoded once per revision, independent of the number of subscribers.
    public static func encodeSnapshot(
        requestID: UUID,
        encodedSnapshot: Data
    ) throws -> Data {
        guard !encodedSnapshot.isEmpty else {
            throw FleetBridgeWireError.invalidRecord("The cached fleet snapshot is empty.")
        }

        let requestIDData = try JSONEncoder().encode(requestID)
        var data = Data(#"{"type":"fleet.snapshot","payload":{"request_id":"#.utf8)
        data.append(requestIDData)
        data.append(Data(#","snapshot":"#.utf8))
        data.append(encodedSnapshot)
        data.append(Data("}}\n".utf8))
        guard data.count <= FleetBridgeProtocol.maximumRecordBytes else {
            throw FleetBridgeWireError.recordTooLarge(
                limit: FleetBridgeProtocol.maximumRecordBytes
            )
        }
        return data
    }

    public static func decodeServer(_ data: Data) throws -> FleetBridgeServerRecord {
        let envelope = try decodeEnvelope(data)
        switch envelope.type {
        case "bridge.challenge": return .challenge(try decode(FleetBridgeChallenge.self, payload: envelope.payload))
        case "bridge.welcome": return .welcome(try decode(FleetBridgeWelcome.self, payload: envelope.payload))
        case "fleet.snapshot": return .snapshot(try decode(FleetBridgeSnapshotRecord.self, payload: envelope.payload))
        case "herdr.response": return .rpc(try decode(FleetBridgeRPCResponse.self, payload: envelope.payload))
        case "terminal.frame": return .terminalFrame(try decode(FleetBridgeTerminalFrameRecord.self, payload: envelope.payload))
        case "terminal.closed": return .terminalClosed(try decode(FleetBridgeTerminalClosedRecord.self, payload: envelope.payload))
        case "bridge.error": return .error(try decode(FleetBridgeErrorRecord.self, payload: envelope.payload))
        default: throw FleetBridgeWireError.unsupportedRecordType(envelope.type)
        }
    }

    private static func line<T: Encodable>(type: String, payload: T) throws -> Data {
        let payloadData = try JSONEncoder().encode(payload)
        let payloadValue = try JSONDecoder().decode(JSONValue.self, from: payloadData)
        return try JSONEncoder().encode(
            JSONValue.object([
                "type": .string(type),
                "payload": payloadValue,
            ])
        ) + Data([0x0A])
    }

    private static func decodeEnvelope(_ data: Data) throws -> Envelope {
        var line = data
        if line.last == 0x0A { line.removeLast() }
        if line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty else { throw FleetBridgeWireError.emptyRecord }
        do {
            return try JSONDecoder().decode(Envelope.self, from: line)
        } catch {
            throw FleetBridgeWireError.invalidRecord(error.localizedDescription)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, payload: JSONValue) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: JSONEncoder().encode(payload))
        } catch {
            throw FleetBridgeWireError.invalidRecord(error.localizedDescription)
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let payload: JSONValue
    }
}

/// Incremental decoder shared by Network.framework connections and tests.
public struct FleetBridgeRecordDecoder: Sendable {
    public let maximumRecordBytes: Int
    private var buffer = Data()

    public init(maximumRecordBytes: Int = FleetBridgeProtocol.maximumRecordBytes) {
        self.maximumRecordBytes = max(1, maximumRecordBytes)
    }

    public var hasBufferedBytes: Bool { !buffer.isEmpty }

    public mutating func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= maximumRecordBytes || buffer.contains(0x0A) else {
            throw FleetBridgeWireError.recordTooLarge(limit: maximumRecordBytes)
        }
    }

    public mutating func nextRecordData() throws -> Data? {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let record = Data(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
            if record.isEmpty || record == Data([0x0D]) { continue }
            guard record.count <= maximumRecordBytes else {
                throw FleetBridgeWireError.recordTooLarge(limit: maximumRecordBytes)
            }
            return record
        }
        if buffer.count > maximumRecordBytes {
            throw FleetBridgeWireError.recordTooLarge(limit: maximumRecordBytes)
        }
        return nil
    }
}
