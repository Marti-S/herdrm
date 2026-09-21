import Foundation

/// Agent status buckets reported by herdr snapshots and status events.
public struct PingResult: Codable, Sendable {
    public let version: String
    public let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
    }
}
