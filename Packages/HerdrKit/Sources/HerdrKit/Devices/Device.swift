import Foundation

/// A machine running herdr. `local` talks straight to the Unix socket;
/// `ssh` reaches the remote socket through an OpenSSH stream-local forward;
/// `tailcat` reaches a socket exposed by the herdr.tailcat server plugin
/// through a WireGuard/DERP tunnel (token in the Keychain, keyed by id).
public struct Device: Codable, Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: Codable, Sendable, Equatable, Hashable {
        case local
        case ssh(target: String)   // e.g. "vincent@10.10.10.87" or "vincent@mac-studio.tail"
        case tailcat
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Socket path override; nil means the default session socket (~/.config/herdr/herdr.sock).
    public var socketPath: String?
    /// Sniffed operating system id ("macos", "ubuntu", "debian", …); cached after first probe.
    public var osID: String?

    public init(id: UUID = UUID(), name: String, kind: Kind, socketPath: String? = nil, osID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.socketPath = socketPath
        self.osID = osID
    }

    public static let local = Device(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Local",
        kind: .local,
        osID: "macos"
    )

    public var isLocal: Bool {
        if case .local = kind { return true }
        return false
    }

    public var sshTarget: String? {
        if case .ssh(let target) = kind { return target }
        return nil
    }

    public var isTailcat: Bool {
        if case .tailcat = kind { return true }
        return false
    }

    /// A named herdr session surfaced as a Local device (issue #81): local, but
    /// pointed at `~/.config/herdr/sessions/<name>/herdr.sock` via `socketPath`.
    public var isNamedSession: Bool {
        isLocal && socketPath != nil
    }

    public var subtitle: String {
        switch kind {
        case .local: return isNamedSession ? "This Mac · session \(name)" : "This Mac · herdr.sock"
        case .ssh(let target): return "\(target) · SSH"
        case .tailcat: return "tailcat tunnel"
        }
    }
}
