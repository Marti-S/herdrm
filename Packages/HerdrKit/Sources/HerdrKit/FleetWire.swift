import Foundation

public enum FleetBridgeProtocol {
    public static let version = 1
    public static let maximumFrameBytes = 64 * 1024 * 1024
}

public enum FleetCapability: String, Codable, Sendable, CaseIterable {
    case observe
    case control
    case manage
}

public struct FleetClientHello: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let clientID: UUID
    public let clientName: String
    public let lastRevision: UInt64?

    public init(
        protocolVersion: Int = FleetBridgeProtocol.version,
        clientID: UUID,
        clientName: String,
        lastRevision: UInt64? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.clientID = clientID
        self.clientName = clientName
        self.lastRevision = lastRevision
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case clientID = "client_id"
        case clientName = "client_name"
        case lastRevision = "last_revision"
    }
}

public struct FleetServerWelcome: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let bridgeID: UUID
    public let bridgeName: String
    public let capabilities: Set<FleetCapability>
    public let snapshot: FleetSnapshot

    public init(
        protocolVersion: Int = FleetBridgeProtocol.version,
        bridgeID: UUID,
        bridgeName: String,
        capabilities: Set<FleetCapability>,
        snapshot: FleetSnapshot
    ) {
        self.protocolVersion = protocolVersion
        self.bridgeID = bridgeID
        self.bridgeName = bridgeName
        self.capabilities = capabilities
        self.snapshot = snapshot
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case bridgeID = "bridge_id"
        case bridgeName = "bridge_name"
        case capabilities
        case snapshot
    }
}

public struct FleetSnapshotUpdate: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case changed
        case resync
    }

    public let reason: Reason
    public let snapshot: FleetSnapshot

    public init(reason: Reason, snapshot: FleetSnapshot) {
        self.reason = reason
        self.snapshot = snapshot
    }
}

public struct FleetRPCRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let deviceID: UUID
    public let method: String
    public let params: JSONValue
    public let minimumRevision: UInt64?

    public init(
        id: UUID = UUID(),
        deviceID: UUID,
        method: String,
        params: JSONValue = .object([:]),
        minimumRevision: UInt64? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.method = method
        self.params = params
        self.minimumRevision = minimumRevision
    }

    enum CodingKeys: String, CodingKey {
        case id
        case deviceID = "device_id"
        case method
        case params
        case minimumRevision = "minimum_revision"
    }
}

public struct FleetRPCError: Codable, Sendable, Equatable, Error {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public struct FleetRPCResponse: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let result: JSONValue?
    public let error: FleetRPCError?

    private init(id: UUID, result: JSONValue?, error: FleetRPCError?) {
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(
        id: UUID,
        result: JSONValue = .null
    ) -> FleetRPCResponse {
        FleetRPCResponse(id: id, result: result, error: nil)
    }

    public static func failure(
        id: UUID,
        error: FleetRPCError
    ) -> FleetRPCResponse {
        FleetRPCResponse(id: id, result: nil, error: error)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)
        guard hasResult != hasError else {
            throw DecodingError.dataCorruptedError(
                forKey: .result,
                in: container,
                debugDescription: "response must contain exactly one of result or error"
            )
        }

        if hasResult {
            self.init(
                id: id,
                result: try container.decode(JSONValue.self, forKey: .result),
                error: nil
            )
        } else {
            self.init(
                id: id,
                result: nil,
                error: try container.decode(FleetRPCError.self, forKey: .error)
            )
        }
    }
}

/// Top-level typed message carried by the length-prefixed bridge stream.
public enum FleetWireMessage: Codable, Sendable, Equatable {
    case hello(FleetClientHello)
    case welcome(FleetServerWelcome)
    case snapshot(FleetSnapshotUpdate)
    case request(FleetRPCRequest)
    case response(FleetRPCResponse)
    case ping
    case pong

    private enum Kind: String, Codable {
        case hello
        case welcome
        case snapshot
        case request
        case response
        case ping
        case pong
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .hello:
            self = .hello(try container.decode(FleetClientHello.self, forKey: .payload))
        case .welcome:
            self = .welcome(try container.decode(FleetServerWelcome.self, forKey: .payload))
        case .snapshot:
            self = .snapshot(try container.decode(FleetSnapshotUpdate.self, forKey: .payload))
        case .request:
            self = .request(try container.decode(FleetRPCRequest.self, forKey: .payload))
        case .response:
            self = .response(try container.decode(FleetRPCResponse.self, forKey: .payload))
        case .ping:
            self = .ping
        case .pong:
            self = .pong
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let value):
            try container.encode(Kind.hello, forKey: .type)
            try container.encode(value, forKey: .payload)
        case .welcome(let value):
            try container.encode(Kind.welcome, forKey: .type)
            try container.encode(value, forKey: .payload)
        case .snapshot(let value):
            try container.encode(Kind.snapshot, forKey: .type)
            try container.encode(value, forKey: .payload)
        case .request(let value):
            try container.encode(Kind.request, forKey: .type)
            try container.encode(value, forKey: .payload)
        case .response(let value):
            try container.encode(Kind.response, forKey: .type)
            try container.encode(value, forKey: .payload)
        case .ping:
            try container.encode(Kind.ping, forKey: .type)
        case .pong:
            try container.encode(Kind.pong, forKey: .type)
        }
    }
}

public enum FleetWireError: Error, LocalizedError, Sendable, Equatable {
    case frameTooLarge(limit: Int)
    case invalidLength
    case invalidMessage(String)

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge(let limit):
            return "The fleet message exceeded \(limit) bytes."
        case .invalidLength:
            return "The fleet message has an invalid length prefix."
        case .invalidMessage(let detail):
            return "The fleet message is invalid: \(detail)"
        }
    }
}

/// Four-byte big-endian length framing for the raw TCP bridge connection.
public enum FleetWireCodec {
    public static func encode(_ message: FleetWireMessage) throws -> Data {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(message)
        } catch {
            throw FleetWireError.invalidMessage(error.localizedDescription)
        }
        guard payload.count <= FleetBridgeProtocol.maximumFrameBytes,
              payload.count <= Int(UInt32.max)
        else {
            throw FleetWireError.frameTooLarge(
                limit: FleetBridgeProtocol.maximumFrameBytes
            )
        }

        var length = UInt32(payload.count).bigEndian
        var frame = Data()
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

public struct FleetWireDecoder: Sendable {
    public let maximumFrameBytes: Int
    private var buffer = Data()

    public init(maximumFrameBytes: Int = FleetBridgeProtocol.maximumFrameBytes) {
        self.maximumFrameBytes = max(maximumFrameBytes, 1)
    }

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        buffer.append(data)
        try validateAvailableLength()
    }

    public mutating func nextMessage() throws -> FleetWireMessage? {
        guard buffer.count >= 4 else { return nil }
        let length = try payloadLength()
        guard length <= maximumFrameBytes else {
            throw FleetWireError.frameTooLarge(limit: maximumFrameBytes)
        }
        let total = 4 + length
        guard buffer.count >= total else { return nil }

        let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
        let payloadEnd = buffer.index(payloadStart, offsetBy: length)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        do {
            return try JSONDecoder().decode(FleetWireMessage.self, from: payload)
        } catch {
            throw FleetWireError.invalidMessage(error.localizedDescription)
        }
    }

    private func validateAvailableLength() throws {
        guard buffer.count >= 4 else { return }
        let length = try payloadLength()
        guard length <= maximumFrameBytes else {
            throw FleetWireError.frameTooLarge(limit: maximumFrameBytes)
        }
    }

    private func payloadLength() throws -> Int {
        guard buffer.count >= 4 else { throw FleetWireError.invalidLength }
        let value = buffer.prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard value > 0 else { throw FleetWireError.invalidLength }
        return Int(value)
    }
}
