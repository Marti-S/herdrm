import Foundation
import HerdrKit
import Security

struct FleetBridgeHostConfiguration: Equatable {
    static let enabledKey = "fleetBridge.enabled"
    static let portKey = "fleetBridge.port"
    static let bindAllInterfacesKey = "fleetBridge.bindAllInterfaces"

    let enabled: Bool
    let port: UInt16
    let bindAllInterfaces: Bool

    static func load(defaults: UserDefaults = .standard) -> FleetBridgeHostConfiguration {
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        let rawPort = defaults.integer(forKey: portKey)
        let port = rawPort > 0
            ? (UInt16(exactly: rawPort) ?? FleetBridgeProtocol.defaultPort)
            : FleetBridgeProtocol.defaultPort
        let bindAll = defaults.bool(forKey: bindAllInterfacesKey)
        return FleetBridgeHostConfiguration(
            enabled: enabled,
            port: port,
            bindAllInterfaces: bindAll
        )
    }
}

struct FleetBridgePairingInfo: Codable, Equatable {
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

enum FleetBridgeCredentialStore {
    private static let tokenService = "dev.bybee.herdrm.fleet-bridge"
    private static let tokenAccount = "host-token"
    private static let serverIDKey = "fleetBridge.serverID"

    static var pairingInfoURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrM", isDirectory: true)
        return base.appendingPathComponent("mobile-pairing.json")
    }

    static func serverID(defaults: UserDefaults = .standard) -> UUID {
        if let raw = defaults.string(forKey: serverIDKey),
           let existing = UUID(uuidString: raw) {
            return existing
        }
        let value = UUID()
        defaults.set(value.uuidString, forKey: serverIDKey)
        return value
    }

    static func token() throws -> String {
        if let existing = try loadToken() { return existing }
        return try rotateToken()
    }

    @discardableResult
    static func rotateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw FleetBridgeCredentialError(status: status)
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try saveToken(token)
        return token
    }

    static func writePairingInfo(
        configuration: FleetBridgeHostConfiguration,
        serverName: String
    ) throws {
        let info = FleetBridgePairingInfo(
            protocolVersion: FleetBridgeProtocol.version,
            serverID: serverID(),
            serverName: serverName,
            hostHint: ProcessInfo.processInfo.hostName,
            port: configuration.port,
            token: try token(),
            loopbackOnly: !configuration.bindAllInterfaces
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(info)
        let url = pairingInfoURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func constantTimeMatches(_ candidate: String, _ expected: String) -> Bool {
        let lhs = Array(candidate.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func loadToken() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw FleetBridgeCredentialError(status: status == errSecSuccess ? errSecDecode : status)
        }
        return value
    }

    private static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = baseQuery()
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw FleetBridgeCredentialError(status: update)
        }
        var item = query
        item.merge(attributes) { _, new in new }
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw FleetBridgeCredentialError(status: add) }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount,
        ]
    }
}

struct FleetBridgeCredentialError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "could not access the mobile bridge credential: \(detail)"
    }
}
