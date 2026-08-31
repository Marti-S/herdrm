import Foundation
import HerdrKit
import Security
import UIKit

/// One paired Mac running the fleet bridge. The bearer token is stored in the
/// iOS Keychain; this value contains only routing and display metadata.
struct MobileBridgeEndpoint: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var serverID: UUID?
    var name: String
    var host: String
    var port: UInt16

    init(
        id: UUID = UUID(),
        serverID: UUID? = nil,
        name: String,
        host: String,
        port: UInt16 = FleetBridgeProtocol.defaultPort
    ) {
        self.id = id
        self.serverID = serverID
        self.name = name
        self.host = host
        self.port = port
    }

    var subtitle: String {
        port == FleetBridgeProtocol.defaultPort ? host : "\(host):\(port)"
    }
}

/// The JSON payload written by the Mac host to `mobile-pairing.json`.
struct MobileBridgePairingPayload: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let serverID: UUID
    let serverName: String
    let hostHint: String
    let port: UInt16
    let token: String
    let loopbackOnly: Bool

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case serverID = "server_id"
        case serverName = "server_name"
        case hostHint = "host_hint"
        case port
        case token
        case loopbackOnly = "loopback_only"
    }
}

@MainActor
final class MobileBridgeStore {
    private static let key = "fleetBridges.v1"

    func load() -> [MobileBridgeEndpoint] {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let endpoints = try? JSONDecoder().decode([MobileBridgeEndpoint].self, from: data)
        else { return [] }
        return endpoints
    }

    func save(_ endpoints: [MobileBridgeEndpoint]) {
        guard let data = try? JSONEncoder().encode(endpoints) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

enum MobileBridgeSecretStore {
    private static let service = "dev.bybee.herdrm.ios.fleet-bridge"

    static func token(for endpointID: UUID) -> String? {
        var query = baseQuery(endpointID: endpointID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for endpointID: UUID) {
        let data = Data(token.utf8)
        var query = baseQuery(endpointID: endpointID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { return }
        query.merge(attributes) { _, new in new }
        SecItemAdd(query as CFDictionary, nil)
    }

    static func removeToken(for endpointID: UUID) {
        SecItemDelete(baseQuery(endpointID: endpointID) as CFDictionary)
    }

    private static func baseQuery(endpointID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpointID.uuidString,
        ]
    }
}

enum MobileBridgeClientIdentity {
    private static let idKey = "fleetBridge.clientID"

    static var id: UUID {
        if let raw = UserDefaults.standard.string(forKey: idKey),
           let existing = UUID(uuidString: raw) {
            return existing
        }
        let value = UUID()
        UserDefaults.standard.set(value.uuidString, forKey: idKey)
        return value
    }

    static var name: String {
        UIDevice.current.name
    }
}
