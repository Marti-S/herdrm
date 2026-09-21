import CryptoKit
import Foundation
import HerdrKit
import HerdrSSH

/// How the phone reaches a device's herdr session: direct SSH with a
/// `direct-streamlocal` channel per RPC (herdr is one-request-per-connection),
/// the Mac fleet bridge, or the tailcat tunnel re-served on a local Unix socket
/// by the embedded bridge (same NDJSON API, no shell). Every transport
/// implements the same RPC, event, terminal, and attachment surface.
///
/// Deliberately not constrained to `AnyObject`: `FleetBridgeDeviceTransport` is
/// a value type that forwards to a shared client actor.
protocol MobileTransport: Sendable {
    func request(method: String, params: JSONValue) async throws -> JSONValue
    /// `statusPaneIDs` scopes herdr 0.9.0's pane-scoped `pane.agent_status_changed`.
    func events(kinds: [String], statusPaneIDs: [String]) -> AsyncThrowingStream<HerdrEvent, Error>
    func openTerminalSession(
        target: TerminalAttachTarget,
        mode: TerminalSessionMode,
        size: TerminalSize
    ) async throws -> any TerminalSession
    func stageAttachment(_ attachment: MobileAttachmentPayload) async throws -> String
    /// Tails an agent session transcript by byte range (see `FileRangeRead`).
    func readFileRange(path: String, offset: Int64, limit: Int) async throws -> FileRangeRead
    func close() async
}

extension MobileTransport {
    func request<T: Decodable>(
        method: String,
        params: JSONValue = .object([:]),
        as type: T.Type
    ) async throws -> T {
        let result = try await request(method: method, params: params)
        let data = try JSONEncoder().encode(result)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HerdrError.malformedResponse("\(method): \(error)")
        }
    }
}

enum MobileTransportError: LocalizedError {
    case hostKeyChanged(fingerprint: String)
    case missingPassword
    case homeProbeFailed
    case invalidTerminalSize
    case tailcatTerminalUnsupported

    var errorDescription: String? {
        switch self {
        case .hostKeyChanged(let fingerprint):
            return String(
                localized: "This device's SSH host key changed (\(fingerprint)). If the host was reinstalled, remove and re-add the device."
            )
        case .missingPassword:
            return String(localized: "No password saved for this device.")
        case .homeProbeFailed:
            return String(localized: "Could not resolve the home directory on the device.")
        case .invalidTerminalSize:
            return String(localized: "Terminal columns and rows must be greater than zero.")
        case .tailcatTerminalUnsupported:
            return String(localized: "Terminal attach isn't available over tailcat on iOS yet — the tunnel carries herdr's control plane only.")
        }
    }
}
