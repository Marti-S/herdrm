import Foundation

/// A network endpoint for one Mac bridge. The host may be a Tailscale MagicDNS
/// name, a Tailscale IP, or a local-network address. Credentials are deliberately
/// not embedded in this value so endpoint metadata can be displayed safely.
public struct FleetBridgeEndpoint: Codable, Sendable, Equatable, Hashable {
    public let bridgeID: UUID
    public let name: String
    public let host: String
    public let port: UInt16
    /// SHA-256 fingerprint of the bridge TLS public key, without a `SHA256:` prefix.
    /// Nil is accepted for development endpoints but pairing UI should call it out.
    public let tlsPublicKeyFingerprint: String?

    public init(
        bridgeID: UUID,
        name: String,
        host: String,
        port: UInt16,
        tlsPublicKeyFingerprint: String? = nil
    ) {
        self.bridgeID = bridgeID
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.tlsPublicKeyFingerprint = tlsPublicKeyFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool {
        !name.isEmpty
            && !host.isEmpty
            && !host.utf8.contains(0)
            && (tlsPublicKeyFingerprint.map(Self.isFingerprint) ?? true)
    }

    private static func isFingerprint(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.count == 64 && normalized.allSatisfy(\.isHexDigit)
    }
}

/// High-entropy, one-use secret encoded into the Mac's pairing QR code.
///
/// This is not the long-lived client credential. A bridge consumes it once and
/// returns a separate credential that can later be revoked without changing the
/// bridge identity or invalidating other phones.
public struct FleetPairingSecret: Codable, Sendable, Equatable, Hashable {
    public static let minimumByteCount = 32

    public let value: String

    public init?(value: String) {
        guard let bytes = Self.decodeBase64URL(value), bytes.count >= Self.minimumByteCount else {
            return nil
        }
        self.value = value
    }

    public init?(bytes: Data) {
        guard bytes.count >= Self.minimumByteCount else { return nil }
        self.value = Self.encodeBase64URL(bytes)
    }

    public var bytes: Data {
        Self.decodeBase64URL(value) ?? Data()
    }

    public static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  ("A"..."Z").contains(Character(String($0)))
                      || ("a"..."z").contains(Character(String($0)))
                      || ("0"..."9").contains(Character(String($0)))
                      || $0 == "-" || $0 == "_"
              })
        else { return nil }

        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        return Data(base64Encoded: base64)
    }
}

/// A short-lived invitation displayed by the Mac and imported by iOS.
public struct FleetPairingInvitation: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let urlScheme = "herdrm"
    public static let urlHost = "pair"

    public let version: Int
    public let invitationID: UUID
    public let endpoint: FleetBridgeEndpoint
    public let secret: FleetPairingSecret
    public let expiresAt: Date

    public init(
        version: Int = Self.currentVersion,
        invitationID: UUID = UUID(),
        endpoint: FleetBridgeEndpoint,
        secret: FleetPairingSecret,
        expiresAt: Date
    ) {
        self.version = version
        self.invitationID = invitationID
        self.endpoint = endpoint
        self.secret = secret
        self.expiresAt = expiresAt
    }

    public func isValid(at date: Date = Date()) -> Bool {
        version == Self.currentVersion && endpoint.isValid && expiresAt > date
    }

    /// Compact custom URL suitable for a QR code or copy/paste fallback.
    public var url: URL? {
        guard isValid(at: Date.distantPast) else { return nil }
        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = Self.urlHost
        components.queryItems = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "invitation", value: invitationID.uuidString),
            URLQueryItem(name: "bridge", value: endpoint.bridgeID.uuidString),
            URLQueryItem(name: "name", value: endpoint.name),
            URLQueryItem(name: "host", value: endpoint.host),
            URLQueryItem(name: "port", value: String(endpoint.port)),
            URLQueryItem(name: "fingerprint", value: endpoint.tlsPublicKeyFingerprint),
            URLQueryItem(name: "secret", value: secret.value),
            URLQueryItem(
                name: "expires",
                value: String(Int(expiresAt.timeIntervalSince1970.rounded(.down)))
            ),
        ]
        return components.url
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.urlScheme,
              components.host?.lowercased() == Self.urlHost
        else { return nil }

        let values = Dictionary(
            components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        guard let versionString = values["v"],
              let version = Int(versionString),
              version == Self.currentVersion,
              let invitationString = values["invitation"],
              let invitationID = UUID(uuidString: invitationString),
              let bridgeString = values["bridge"],
              let bridgeID = UUID(uuidString: bridgeString),
              let name = values["name"],
              let host = values["host"],
              let portString = values["port"],
              let port = UInt16(portString),
              let secretString = values["secret"],
              let secret = FleetPairingSecret(value: secretString),
              let expirationString = values["expires"],
              let expirationSeconds = TimeInterval(expirationString)
        else { return nil }

        let endpoint = FleetBridgeEndpoint(
            bridgeID: bridgeID,
            name: name,
            host: host,
            port: port,
            tlsPublicKeyFingerprint: values["fingerprint"]
        )
        guard endpoint.isValid else { return nil }
        self.init(
            version: version,
            invitationID: invitationID,
            endpoint: endpoint,
            secret: secret,
            expiresAt: Date(timeIntervalSince1970: expirationSeconds)
        )
    }
}

/// Revocable credential issued after a successful one-time pairing exchange.
/// The token is opaque to the client and must be stored in the platform Keychain.
public struct FleetClientCredential: Codable, Sendable, Equatable {
    public let bridgeID: UUID
    public let clientID: UUID
    public let clientName: String
    public let token: String
    public let capabilities: Set<FleetCapability>
    public let issuedAt: Date

    public init(
        bridgeID: UUID,
        clientID: UUID,
        clientName: String,
        token: String,
        capabilities: Set<FleetCapability>,
        issuedAt: Date
    ) {
        self.bridgeID = bridgeID
        self.clientID = clientID
        self.clientName = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token
        self.capabilities = capabilities
        self.issuedAt = issuedAt
    }

    public var isValid: Bool {
        !clientName.isEmpty
            && (FleetPairingSecret.decodeBase64URL(token)?.count ?? 0)
                >= FleetPairingSecret.minimumByteCount
    }
}