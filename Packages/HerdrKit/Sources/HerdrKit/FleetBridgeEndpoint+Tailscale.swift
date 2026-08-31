import Foundation

public extension FleetBridgeEndpoint {
    /// Whether the endpoint is addressed through the tailnet rather than an
    /// ordinary LAN/WAN address. Raw TCP bridge traffic is allowed only on this
    /// path until certificate-pinned TLS is enabled.
    var isTailscaleAddress: Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if normalized.hasSuffix(".ts.net") { return true }
        if normalized.hasPrefix("fd7a:115c:a1e0:") { return true }

        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let first = UInt8(parts[0]),
              let second = UInt8(parts[1]),
              UInt8(parts[2]) != nil,
              UInt8(parts[3]) != nil
        else { return false }
        // Tailscale's CGNAT allocation is 100.64.0.0/10.
        return first == 100 && (64...127).contains(second)
    }

    var isLoopbackAddress: Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if normalized == "localhost" || normalized == "::1" { return true }
        return normalized.hasPrefix("127.")
    }
}