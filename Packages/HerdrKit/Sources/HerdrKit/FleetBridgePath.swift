import Foundation

/// Stable location of the per-user Mac fleet bridge socket.
///
/// The parent directory is private (0700) and the socket is 0600. iOS resolves
/// the remote numeric uid over SSH, then opens this path with direct-streamlocal.
public enum FleetBridgePath {
    public static func unixSocketPath(userID: UInt32) -> String {
        "/tmp/herdrm-\(userID)/bridge.sock"
    }
}
