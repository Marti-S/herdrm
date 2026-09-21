import Foundation

/// Agent status buckets reported by herdr snapshots and status events.
public enum HerdrError: Error, LocalizedError, Sendable {
    case socketUnavailable(String)
    case connectionFailed(String)
    case herdrNotInstalled
    case remoteHerdrDown(target: String, socketPath: String)
    case rpc(code: String, message: String)
    case malformedResponse(String)
    case incompatibleProtocol(Int)
    case tunnelFailed(String)
    case fileOperationFailed(String)
    case fileTransferFailed(String)
    case tailcatTokenMissing
    case tailcatBridgeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .socketUnavailable(let path): return "herdr socket not found at \(path)"
        case .connectionFailed(let reason): return "connection failed: \(reason)"
        case .herdrNotInstalled: return "herdr not found on herdrm's PATH — install it with \"brew install herdr\""
        case .remoteHerdrDown(let target, let socketPath):
            return "herdr isn't running on \(target) — nothing listens at \(socketPath); start it by running \"herdr\" on that machine"
        case .rpc(let code, let message): return "herdr error \(code): \(message)"
        case .malformedResponse(let reason): return "malformed response: \(reason)"
        case .incompatibleProtocol(let version): return "herdr protocol \(version) is too old (need >= 17)"
        case .tunnelFailed(let reason): return "SSH tunnel failed: \(reason)"
        case .fileOperationFailed(let reason): return "file operation failed: \(reason)"
        case .fileTransferFailed(let reason): return "file transfer failed: \(reason)"
        case .tailcatTokenMissing: return "no tailcat token saved for this device"
        case .tailcatBridgeFailed(let reason): return "tailcat tunnel failed: \(reason)"
        }
    }
}

/// What an embedded terminal attaches to: an agent pane or a bare herdr terminal.
