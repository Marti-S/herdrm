import Combine
import Foundation
import HerdrKit

@MainActor
final class FleetBridgePairingController: ObservableObject {
    static let shared = FleetBridgePairingController()
    static let defaultPort: UInt16 = 45123

    enum Status: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var currentInvitation: FleetPairingInvitation?
    @Published private(set) var pairedClients: [FleetPairedClientRecord] = []

    private let store: FleetBridgeStateStore
    private var bridgeID: UUID
    private var authority: FleetBridgePairingAuthority?
    private var server: FleetBridgePairingServer?
    private var startTask: Task<Void, Never>?

    init(store: FleetBridgeStateStore = FleetBridgeStateStore()) {
        self.store = store
        let state = store.loadOrCreate()
        bridgeID = state.bridgeID
        pairedClients = state.clients
    }

    deinit {
        startTask?.cancel()
        server?.stop()
    }

    func start(port: UInt16 = defaultPort, bindHost: String? = "127.0.0.1") {
        guard case .stopped = status else { return }
        status = .starting
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let bridgeID = self.bridgeID
                let store = self.store
                let authority = FleetBridgePairingAuthority(
                    bridgeID: bridgeID,
                    clients: self.pairedClients,
                    recordsChanged: { [weak self, store] records in
                        store.saveClients(records, bridgeID: bridgeID)
                        await MainActor.run {
                            self?.pairedClients = records
                        }
                    }
                )
                let server = try FleetBridgePairingServer(
                    authority: authority,
                    port: port,
                    bindHost: bindHost
                )
                let boundPort = try await server.start()
                guard !Task.isCancelled else {
                    server.stop()
                    return
                }
                self.authority = authority
                self.server = server
                self.status = .running(port: boundPort)
            } catch {
                guard !Task.isCancelled else { return }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        server?.stop()
        server = nil
        authority = nil
        currentInvitation = nil
        status = .stopped
    }

    /// Creates a five-minute invitation for the Mac's MagicDNS name or Tailscale
    /// IP. Pairing over ordinary LAN/WAN addresses stays disabled until the
    /// network carrier has certificate-pinned TLS.
    func createInvitation(
        host: String,
        bridgeName: String = Host.current().localizedName ?? "Mac",
        lifetime: TimeInterval = 5 * 60
    ) async throws -> FleetPairingInvitation {
        guard case .running(let port) = status, let authority else {
            throw FleetBridgePairingControllerError.notRunning
        }
        let endpoint = FleetBridgeEndpoint(
            bridgeID: bridgeID,
            name: bridgeName,
            host: host,
            port: port
        )
        guard endpoint.isTailscaleAddress else {
            throw FleetBridgePairingControllerError.tailscaleRequired
        }
        let invitation = try await authority.makeInvitation(
            endpoint: endpoint,
            lifetime: lifetime
        )
        currentInvitation = invitation
        return invitation
    }

    func revokeInvitation() async {
        guard let invitation = currentInvitation else { return }
        await authority?.revokeInvitation(invitation.invitationID)
        currentInvitation = nil
    }

    func revoke(clientID: UUID) async {
        await authority?.revoke(clientID: clientID)
    }

    func resetIdentity() {
        stop()
        let state = store.reset()
        bridgeID = state.bridgeID
        pairedClients = []
    }
}

enum FleetBridgePairingControllerError: Error, LocalizedError {
    case notRunning
    case tailscaleRequired

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Start the mobile bridge before creating a pairing invitation."
        case .tailscaleRequired:
            return "Enter this Mac's Tailscale MagicDNS name or Tailscale IP."
        }
    }
}