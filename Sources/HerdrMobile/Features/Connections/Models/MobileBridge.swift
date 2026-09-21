import Foundation
import HerdrKit
import Security
import UIKit

/// One paired HerdrM host. The bridge owns its Mac-side local and SSH-backed
/// devices, so those SSH targets and credentials never need to be copied here.
struct MobileBridge: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  var expectedServerID: UUID?
  var name: String
  var host: String
  var port: UInt16

  init(
    id: UUID = UUID(),
    expectedServerID: UUID? = nil,
    name: String,
    host: String,
    port: UInt16 = FleetBridgeProtocol.defaultPort
  ) {
    self.id = id
    self.expectedServerID = expectedServerID
    self.name = name
    self.host = host
    self.port = port
  }

  var subtitle: String {
    port == FleetBridgeProtocol.defaultPort ? host : "\(host):\(port)"
  }
}

/// JSON written by the Mac to
/// `~/Library/Application Support/HerdrM/mobile-pairing.json`.
struct MobileBridgePairingInfo: Codable, Equatable {
  let protocolVersion: Int
  let serverID: UUID
  let serverName: String
  let hostHint: String
  let port: UInt16
  let token: String
  let loopbackOnly: Bool
  let networkScope: FleetBridgeNetworkScope?

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol"
    case serverID = "server_id"
    case serverName = "server_name"
    case hostHint = "host_hint"
    case port
    case token
    case loopbackOnly = "loopback_only"
    case networkScope = "network_scope"
  }

  var resolvedNetworkScope: FleetBridgeNetworkScope {
    networkScope ?? (loopbackOnly ? .loopback : .allInterfaces)
  }

  static func decode(_ text: String) throws -> MobileBridgePairingInfo {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8), !data.isEmpty else {
      throw MobileBridgePairingError.empty
    }
    let info: MobileBridgePairingInfo
    do {
      info = try JSONDecoder().decode(MobileBridgePairingInfo.self, from: data)
    } catch {
      throw MobileBridgePairingError.invalid(error.localizedDescription)
    }
    guard info.protocolVersion == FleetBridgeProtocol.version else {
      throw MobileBridgePairingError.protocolMismatch(info.protocolVersion)
    }
    guard !info.token.isEmpty, info.port > 0 else {
      throw MobileBridgePairingError.invalid("The token or port is missing.")
    }
    return info
  }
}

enum MobileBridgePairingError: LocalizedError {
  case empty
  case invalid(String)
  case protocolMismatch(Int)

  var errorDescription: String? {
    switch self {
    case .empty:
      return String(localized: "The pairing JSON is empty.")
    case .invalid(let detail):
      return String(localized: "The pairing JSON is invalid: \(detail)")
    case .protocolMismatch(let version):
      return String(
        localized:
          "This Mac uses bridge protocol \(version), but this app supports \(FleetBridgeProtocol.version)."
      )
    }
  }
}
