import Foundation

/// Network scope used by the Mac fleet bridge and exported in pairing data.
public enum FleetBridgeNetworkScope: String, Codable, Sendable {
    /// The listener is bound to one active Tailscale IPv4 address.
    case tailscale
    /// Tailscale is unavailable, so the listener is reachable from this Mac only.
    case loopback
    /// The user explicitly opted into every available interface, including LAN.
    case allInterfaces = "all-interfaces"
}

/// One active IPv4 address considered when choosing the bridge listener.
public struct FleetBridgeIPv4Interface: Equatable, Sendable {
    public let name: String
    public let address: String
    public let isUp: Bool
    public let isLoopback: Bool

    public init(
        name: String,
        address: String,
        isUp: Bool = true,
        isLoopback: Bool = false
    ) {
        self.name = name
        self.address = address
        self.isUp = isUp
        self.isLoopback = isLoopback
    }
}

/// The exact listener endpoint and the address placed in pairing JSON.
public struct FleetBridgeNetworkIdentity: Equatable, Sendable {
    /// nil means Network.framework should listen on every interface.
    public let bindHost: String?
    public let pairingHost: String
    public let scope: FleetBridgeNetworkScope

    public init(
        bindHost: String?,
        pairingHost: String,
        scope: FleetBridgeNetworkScope
    ) {
        self.bindHost = bindHost
        self.pairingHost = pairingHost
        self.scope = scope
    }

    public static let loopback = FleetBridgeNetworkIdentity(
        bindHost: "127.0.0.1",
        pairingHost: "127.0.0.1",
        scope: .loopback
    )

    public var loopbackOnly: Bool { scope == .loopback }
}

/// Pure listener selection shared by production code and package tests.
public enum FleetBridgeNetworkSelector {
    /// Selects an exact Tailscale tunnel address by default. Listening on every
    /// interface remains an explicit override because it also exposes the
    /// bridge on Wi-Fi, Ethernet, and other local networks.
    public static func select(
        interfaces: [FleetBridgeIPv4Interface],
        bindAllInterfaces: Bool,
        fallbackHost: String
    ) -> FleetBridgeNetworkIdentity {
        let tailscale = preferredTailscaleInterface(from: interfaces)

        if bindAllInterfaces {
            let fallback = normalizedFallbackHost(fallbackHost)
            return FleetBridgeNetworkIdentity(
                bindHost: nil,
                pairingHost: tailscale?.address ?? fallback,
                scope: .allInterfaces
            )
        }

        if let tailscale {
            return FleetBridgeNetworkIdentity(
                bindHost: tailscale.address,
                pairingHost: tailscale.address,
                scope: .tailscale
            )
        }

        return .loopback
    }

    /// Tailscale assigns IPv4 addresses from 100.64.0.0/10.
    public static func isTailscaleIPv4(_ address: String) -> Bool {
        guard let octets = ipv4Octets(address) else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    public static func preferredTailscaleInterface(
        from interfaces: [FleetBridgeIPv4Interface]
    ) -> FleetBridgeIPv4Interface? {
        interfaces
            .filter {
                $0.isUp
                    && !$0.isLoopback
                    && isTailscaleInterfaceName($0.name)
                    && isTailscaleIPv4($0.address)
            }
            .sorted(by: preferredOrder)
            .first
    }

    private static func isTailscaleInterfaceName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("tailscale") || lowered.hasPrefix("utun")
    }

    private static func preferredOrder(
        _ lhs: FleetBridgeIPv4Interface,
        _ rhs: FleetBridgeIPv4Interface
    ) -> Bool {
        let lhsRank = interfaceNameRank(lhs.name)
        let rhsRank = interfaceNameRank(rhs.name)
        if lhsRank != rhsRank { return lhsRank < rhsRank }

        let lhsAddress = ipv4Integer(lhs.address) ?? UInt32.max
        let rhsAddress = ipv4Integer(rhs.address) ?? UInt32.max
        if lhsAddress != rhsAddress { return lhsAddress < rhsAddress }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func interfaceNameRank(_ name: String) -> Int {
        name.lowercased().contains("tailscale") ? 0 : 1
    }

    private static func normalizedFallbackHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "127.0.0.1" : trimmed
    }

    private static func ipv4Integer(_ address: String) -> UInt32? {
        guard let octets = ipv4Octets(address) else { return nil }
        return octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func ipv4Octets(_ address: String) -> [UInt8]? {
        let components = address.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 4 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(4)
        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  let value = UInt8(component)
            else { return nil }
            result.append(value)
        }
        return result
    }
}
