import Foundation
import HerdrSSH

extension SSHSFTPClient {
    /// Label-order adapter used by the mobile attachment pipeline.
    func setPermissions(
        at path: String,
        permissions: UInt32,
        timeout: Duration
    ) async throws {
        try await setPermissions(permissions, at: path, timeout: timeout)
    }
}
