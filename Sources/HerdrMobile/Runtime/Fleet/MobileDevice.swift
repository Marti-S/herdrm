import Foundation
import Security

/// A Mac (or other host) running herdr, reached over SSH or through the
/// herdr.tailcat plugin's tunnel. Unlike the Mac app there is no "Local"
/// device — the phone always talks to a remote herdr. Secrets never live
/// here: SSH passwords and tailcat tokens go to the Keychain keyed by `id`.
struct MobileDevice: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case ssh
        /// Control plane only on iOS: the tunnel carries the herdr API and
        /// client sockets but no shell, so terminal attach stays SSH-only.
        case tailcat
    }

    enum AuthMethod: String, Codable, CaseIterable {
        /// This phone's Ed25519 key, enrolled in the host's authorized_keys.
        case deviceKey
        case password
    }

    var id: UUID
    var kind: Kind
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var authMethod: AuthMethod
    /// Socket path override; nil means ~/.config/herdr/herdr.sock on the host.
    var socketPath: String?

    init(
        id: UUID = UUID(),
        kind: Kind = .ssh,
        name: String,
        host: String = "",
        port: UInt16 = 22,
        username: String = "",
        authMethod: AuthMethod = .deviceKey,
        socketPath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.socketPath = socketPath
    }

    /// Devices stored before the tailcat kind existed decode as SSH.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .ssh
        name = try container.decode(String.self, forKey: .name)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 22
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .deviceKey
        socketPath = try container.decodeIfPresent(String.self, forKey: .socketPath)
    }

    var isTailcat: Bool { kind == .tailcat }

    var subtitle: String {
        switch kind {
        case .ssh:
            return port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
        case .tailcat:
            return String(localized: "Tailcat tunnel")
        }
    }
}
