import Foundation

public enum FleetPairingClientMessage: Sendable, Equatable {
    case redeem(FleetPairingRequest)
}

extension FleetPairingClientMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, request }
    private enum Kind: String, Codable { case redeem }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .redeem:
            self = .redeem(try container.decode(FleetPairingRequest.self, forKey: .request))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .redeem(let request):
            try container.encode(Kind.redeem, forKey: .type)
            try container.encode(request, forKey: .request)
        }
    }
}

public struct FleetPairingRemoteError: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum FleetPairingServerMessage: Sendable, Equatable {
    case credential(FleetClientCredential)
    case error(FleetPairingRemoteError)
}

extension FleetPairingServerMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, credential, error }
    private enum Kind: String, Codable { case credential, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .credential:
            self = .credential(
                try container.decode(FleetClientCredential.self, forKey: .credential)
            )
        case .error:
            self = .error(
                try container.decode(FleetPairingRemoteError.self, forKey: .error)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .credential(let credential):
            try container.encode(Kind.credential, forKey: .type)
            try container.encode(credential, forKey: .credential)
        case .error(let error):
            try container.encode(Kind.error, forKey: .type)
            try container.encode(error, forKey: .error)
        }
    }
}

public enum FleetPairingWireError: Error, LocalizedError, Sendable, Equatable {
    case emptyFrame
    case frameTooLarge(Int)
    case malformedFrame(String)
    case unexpectedEOF

    public var errorDescription: String? {
        switch self {
        case .emptyFrame: return "the pairing peer sent an empty frame"
        case .frameTooLarge(let limit): return "the pairing frame exceeded \(limit) bytes"
        case .malformedFrame(let detail): return "malformed pairing frame: \(detail)"
        case .unexpectedEOF: return "the pairing connection ended mid-frame"
        }
    }
}

/// One small length-prefixed JSON record used only before a client has a normal
/// fleet credential. The normal fleet channel remains a separate connection,
/// which keeps unauthenticated input out of the long-lived bridge session.
public enum FleetPairingWire {
    public static let maximumPayloadBytes = 128 * 1024

    public static func encode<Message: Encodable>(_ message: Message) throws -> Data {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(message)
        } catch {
            throw FleetPairingWireError.malformedFrame(error.localizedDescription)
        }
        guard !payload.isEmpty else { throw FleetPairingWireError.emptyFrame }
        guard payload.count <= maximumPayloadBytes else {
            throw FleetPairingWireError.frameTooLarge(maximumPayloadBytes)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }
}

public struct FleetPairingWireDecoder<Message: Decodable>: Sendable {
    private var buffer = Data()
    private let maximumPayloadBytes: Int

    public init(maximumPayloadBytes: Int = FleetPairingWire.maximumPayloadBytes) {
        precondition(maximumPayloadBytes > 0 && maximumPayloadBytes <= Int(UInt32.max))
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    public mutating func append(_ data: Data) throws -> [Message] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var messages: [Message] = []

        while buffer.count >= MemoryLayout<UInt32>.size {
            let start = buffer.startIndex
            let b0 = UInt32(buffer[start])
            let b1 = UInt32(buffer[buffer.index(start, offsetBy: 1)])
            let b2 = UInt32(buffer[buffer.index(start, offsetBy: 2)])
            let b3 = UInt32(buffer[buffer.index(start, offsetBy: 3)])
            let length = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            guard length > 0 else { throw FleetPairingWireError.emptyFrame }
            guard length <= maximumPayloadBytes else {
                throw FleetPairingWireError.frameTooLarge(maximumPayloadBytes)
            }
            let frameLength = MemoryLayout<UInt32>.size + length
            guard buffer.count >= frameLength else { break }

            let payloadStart = buffer.index(start, offsetBy: MemoryLayout<UInt32>.size)
            let payloadEnd = buffer.index(payloadStart, offsetBy: length)
            let payload = Data(buffer[payloadStart..<payloadEnd])
            do {
                messages.append(try JSONDecoder().decode(Message.self, from: payload))
            } catch {
                throw FleetPairingWireError.malformedFrame(error.localizedDescription)
            }
            buffer.removeSubrange(start..<payloadEnd)
        }
        return messages
    }

    public mutating func finish() throws {
        guard buffer.isEmpty else { throw FleetPairingWireError.unexpectedEOF }
    }
}