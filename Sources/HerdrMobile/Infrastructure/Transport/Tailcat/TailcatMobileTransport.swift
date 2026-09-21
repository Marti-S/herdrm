import CryptoKit
import Foundation
import HerdrKit
import HerdrSSH

/// tailcat control-plane transport: the embedded bridge (HerdrTailcat, via
/// HerdrKit's `TailcatBridgeManager`) holds the WireGuard/DERP session and
/// re-serves the remote herdr API socket on a local Unix socket, so RPC and
/// the event stream are plain `SocketRPC` — the same face the Mac app's
/// tailcat devices use. The tunnel carries no shell, so terminal attach
/// throws; prompting and key input still work, both being socket RPCs.
final class TailcatMobileTransport: MobileTransport {
    private let deviceID: UUID
    private let rpc: SocketRPC

    private init(deviceID: UUID, socketPath: String) {
        self.deviceID = deviceID
        self.rpc = SocketRPC(socketPath: socketPath)
    }

    /// Brings the per-device bridge up (token straight from the Keychain to
    /// the Go runtime) and returns a transport over its local socket. The
    /// bridge binds its listeners before returning; the first tunnel dial
    /// doubles as the handshake, and a bad token surfaces on the first
    /// request via `recentError`.
    static func connect(device: MobileDevice) async throws -> TailcatMobileTransport {
        let socketPath = try await TailcatBridgeManager.shared.ensureUp(deviceID: device.id)
        return TailcatMobileTransport(deviceID: device.id, socketPath: socketPath)
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        do {
            return try await rpc.request(method: method, params: params)
        } catch {
            // A refused tunnel dial reads as a generic socket error; the
            // bridge's recorded error (bad token, unreachable server) is the
            // actionable version, mirroring HerdrService's tailcat path.
            if let detail = await TailcatBridgeManager.shared.recentError(deviceID: deviceID) {
                throw HerdrError.tailcatBridgeFailed(detail)
            }
            throw error
        }
    }

    func events(
        kinds: [String],
        statusPaneIDs: [String]
    ) -> AsyncThrowingStream<HerdrEvent, Error> {
        rpc.events(kinds: kinds, statusPaneIDs: statusPaneIDs)
    }

    /// The tunnel carries herdr's control plane only — no shell, so no PTY.
    func openTerminalSession(
        target _: TerminalAttachTarget,
        mode _: TerminalSessionMode,
        size _: TerminalSize
    ) async throws -> any TerminalSession {
        throw MobileTransportError.tailcatTerminalUnsupported
    }

    /// Attachment staging rides the terminal/SFTP path, which tailcat lacks.
    func stageAttachment(_: MobileAttachmentPayload) async throws -> String {
        throw MobileTransportError.tailcatTerminalUnsupported
    }

    func readFileRange(path _: String, offset _: Int64, limit _: Int) async throws -> FileRangeRead {
        throw MobileTransportError.tailcatTerminalUnsupported
    }

    func close() async {
        await TailcatBridgeManager.shared.tearDown(deviceID: deviceID)
    }
}
