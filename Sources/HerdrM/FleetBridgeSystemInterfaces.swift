import Darwin
import Foundation
import HerdrKit

/// Reads active IPv4 addresses without depending on interface names. Tailscale
/// uses utun devices on macOS, but the stable identification is its
/// 100.64.0.0/10 address range rather than a particular utun number.
enum FleetBridgeSystemInterfaces {
    static func activeIPv4() -> [FleetBridgeIPv4Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }

        var result: [FleetBridgeIPv4Interface] = []
        var seen = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = head

        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next

            guard let address = interface.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET,
                  let rawName = interface.ifa_name
            else { continue }

            let flags = UInt32(interface.ifa_flags)
            let isUp = flags & UInt32(IFF_UP) != 0
            let isLoopback = flags & UInt32(IFF_LOOPBACK) != 0

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = host.withUnsafeMutableBufferPointer { buffer in
                getnameinfo(
                    address,
                    socklen_t(address.pointee.sa_len),
                    buffer.baseAddress,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
            guard status == 0 else { continue }

            let name = String(cString: rawName)
            let value = String(cString: host)
            let key = "\(name)|\(value)"
            guard seen.insert(key).inserted else { continue }
            result.append(FleetBridgeIPv4Interface(
                name: name,
                address: value,
                isUp: isUp,
                isLoopback: isLoopback
            ))
        }

        return result.sorted {
            if $0.name != $1.name {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.address.localizedStandardCompare($1.address) == .orderedAscending
        }
    }
}
