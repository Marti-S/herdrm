import AppKit
import Combine
import Foundation
import HerdrKit
import Network
import os

let fleetBridgeLog = Logger(
    subsystem: "dev.bybee.herdrm",
    category: "fleet-bridge"
)

enum FleetBridgeHostError: LocalizedError {
    case invalidRequest(String)
    case unknownDevice(UUID)
    case unsupportedMethod(String)
    case terminalFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): return detail
        case .unknownDevice(let id): return "No HerdrM device exists with id \(id.uuidString)."
        case .unsupportedMethod(let method): return "The mobile bridge does not allow \(method)."
        case .terminalFailed(let detail): return detail
        }
    }

    var code: String {
        switch self {
        case .invalidRequest: return "invalid_request"
        case .unknownDevice: return "unknown_device"
        case .unsupportedMethod: return "unsupported_method"
        case .terminalFailed: return "terminal_failed"
        }
    }
}

/// In-process host for the Mac-owned fleet.
///
/// The secure default is an exact Tailscale IPv4 listener. When Tailscale is not
/// active, the bridge falls back to loopback rather than exposing itself on the
/// LAN. Listening on every interface remains an explicit user override.
@MainActor
final class FleetBridgeServer: ObservableObject {
    static let shared = FleetBridgeServer()

    private let networkQueue = DispatchQueue(label: "dev.bybee.herdrm.fleet-bridge.network")
    weak var model: AppModel?
    private var listener: NWListener?
    private var listenerID: ObjectIdentifier?
    private var pathMonitor: NWPathMonitor?
    private var pathMonitorGeneration = UUID()
    private var interfaceRefreshTask: Task<Void, Never>?
    private var listenerRetryTask: Task<Void, Never>?
    private var connections: [UUID: FleetBridgeServerConnection] = [:]
    private var subscriptions: [UUID: FleetBridgeServerConnection] = [:]
    private var modelCancellable: AnyCancellable?
    private var publishTask: Task<Void, Never>?
    private var revision: UInt64 = 1
    private var token = ""
    private var configuration = FleetBridgeHostConfiguration.load()

    @Published private(set) var currentNetworkIdentity: FleetBridgeNetworkIdentity = .loopback

    private init() {}

    func start(model: AppModel) {
        self.model = model
        configuration = .load()
        do {
            token = try FleetBridgeCredentialStore.token()
        } catch {
            fleetBridgeLog.error("bridge credentials unavailable: \(error.localizedDescription)")
            return
        }

        modelCancellable?.cancel()
        modelCancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.schedulePublish() }
        }

        reconcileListener(force: true)

        guard configuration.enabled else {
            fleetBridgeLog.notice("mobile bridge disabled by user defaults")
            return
        }
        startNetworkMonitoring()
    }

    func stop() {
        publishTask?.cancel()
        publishTask = nil
        listenerRetryTask?.cancel()
        listenerRetryTask = nil
        interfaceRefreshTask?.cancel()
        interfaceRefreshTask = nil

        pathMonitorGeneration = UUID()
        pathMonitor?.cancel()
        pathMonitor = nil

        modelCancellable?.cancel()
        modelCancellable = nil

        cancelListener()
        for connection in Array(connections.values) {
            connection.close()
        }
        connections.removeAll()
        subscriptions.removeAll()
    }

    var currentRevision: UInt64 { revision }
    var currentToken: String { token }
    var serverID: UUID { FleetBridgeCredentialStore.serverID() }
    var serverName: String {
        Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
    }

    func snapshot() throws -> FleetSnapshot {
        guard let model else {
            throw FleetBridgeHostError.invalidRequest("HerdrM is not ready.")
        }
        return FleetSnapshot(
            revision: revision,
            devices: model.devices.map { deviceSnapshot(device: $0, model: model) }
        )
    }

    func makeTerminalProcess(
        request: FleetBridgeTerminalOpenRequest
    ) throws -> FleetBridgeTerminalProcess {
        guard request.size.isValid else { throw TerminalSessionError.invalidSize }
        guard let model else {
            throw FleetBridgeHostError.invalidRequest("HerdrM is not ready.")
        }
        guard let device = model.device(request.deviceID) else {
            throw FleetBridgeHostError.unknownDevice(request.deviceID)
        }
        let service = model.service(for: device)
        let command = service.terminalSessionCommand(
            target: request.target.attachTarget,
            mode: request.mode,
            size: request.size,
            serverVersion: model.serverVersion(deviceID: device.id)
        )
        return FleetBridgeTerminalProcess(
            streamID: request.streamID,
            mode: request.mode,
            command: command
        )
    }

    func registerSubscription(_ connection: FleetBridgeServerConnection) {
        subscriptions[connection.id] = connection
    }

    func removeConnection(_ connection: FleetBridgeServerConnection) {
        connections.removeValue(forKey: connection.id)
        subscriptions.removeValue(forKey: connection.id)
    }

    /// Re-evaluates the active tailnet address. Cancelling an NWListener does
    /// not cancel NWConnections it already accepted, so an ongoing terminal or
    /// fleet subscription survives a Tailscale address transition whenever the
    /// underlying path itself remains usable.
    private func reconcileListener(force: Bool = false) {
        let nextIdentity = FleetBridgeNetworkSelector.select(
            interfaces: FleetBridgeSystemInterfaces.activeIPv4(),
            bindAllInterfaces: configuration.bindAllInterfaces,
            fallbackHost: ProcessInfo.processInfo.hostName
        )
        let identityChanged = nextIdentity != currentNetworkIdentity

        if force || identityChanged
            || !FileManager.default.fileExists(
                atPath: FleetBridgeCredentialStore.pairingInfoURL.path
            ) {
            do {
                try FleetBridgeCredentialStore.writePairingInfo(
                    configuration: configuration,
                    serverName: serverName,
                    networkIdentity: nextIdentity
                )
            } catch {
                fleetBridgeLog.error(
                    "could not write mobile pairing data: \(error.localizedDescription)"
                )
            }
        }

        if identityChanged {
            currentNetworkIdentity = nextIdentity
        }

        guard configuration.enabled else {
            cancelListener()
            return
        }
        guard force || identityChanged || listener == nil else { return }
        replaceListener(with: nextIdentity)
    }

    private func replaceListener(with identity: FleetBridgeNetworkIdentity) {
        listenerRetryTask?.cancel()
        listenerRetryTask = nil
        cancelListener()

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
                throw FleetBridgeHostError.invalidRequest(
                    "Invalid bridge port \(configuration.port)."
                )
            }
            if let bindHost = identity.bindHost {
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host(bindHost),
                    port: port
                )
            }

            let listener = try NWListener(using: parameters, on: port)
            let id = ObjectIdentifier(listener)
            listenerID = id
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.listenerID == id else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listenerID == id else { return }
                    switch state {
                    case .ready:
                        let endpoint = identity.bindHost ?? "all interfaces"
                        fleetBridgeLog.notice(
                            "mobile bridge listening on \(endpoint):\(self.configuration.port), scope \(identity.scope.rawValue)"
                        )
                    case .failed(let error):
                        fleetBridgeLog.error(
                            "mobile bridge listener failed: \(error.localizedDescription)"
                        )
                        self.cancelListener(ifMatching: id)
                        self.scheduleListenerRetry()
                    case .cancelled:
                        self.cancelListener(ifMatching: id)
                    default:
                        break
                    }
                }
            }
            listener.start(queue: networkQueue)
        } catch {
            fleetBridgeLog.error("could not start mobile bridge: \(error.localizedDescription)")
            scheduleListenerRetry()
        }
    }

    private func cancelListener(ifMatching expectedID: ObjectIdentifier? = nil) {
        if let expectedID, listenerID != expectedID { return }
        let previous = listener
        listener = nil
        listenerID = nil
        previous?.cancel()
    }

    private func scheduleListenerRetry() {
        guard configuration.enabled else { return }
        listenerRetryTask?.cancel()
        listenerRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.reconcileListener(force: true)
        }
    }

    private func startNetworkMonitoring() {
        pathMonitorGeneration = UUID()
        let generation = pathMonitorGeneration
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pathMonitorGeneration == generation else { return }
                self.reconcileListener()
            }
        }
        monitor.start(queue: networkQueue)

        interfaceRefreshTask?.cancel()
        interfaceRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.reconcileListener()
            }
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = FleetBridgeServerConnection(
            connection: nwConnection,
            server: self,
            queue: networkQueue
        )
        connections[connection.id] = connection
        connection.start()
    }

    private func schedulePublish() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            self.revision &+= 1
            guard let snapshot = try? self.snapshot() else { return }
            for connection in self.subscriptions.values {
                connection.sendSubscribedSnapshot(snapshot)
            }
        }
    }

    private func deviceSnapshot(device: Device, model: AppModel) -> FleetDeviceSnapshot {
        let state = model.session(device.id)
        let connection: FleetConnectionInfo
        switch state.connection {
        case .idle: connection = .idle
        case .connecting: connection = .connecting
        case .connected(let version): connection = .connected(version: version)
        case .failed(let message): connection = .failed(message)
        }

        let availableAgentKinds: [String]
        switch state.agentCatalog {
        case .loaded(let kinds, _): availableAgentKinds = kinds
        case .loading, .failed: availableAgentKinds = []
        }

        let hasSnapshot = !state.agents.isEmpty
            || !state.workspaces.isEmpty
            || !state.tabs.isEmpty
            || !state.panes.isEmpty
            || connection.phase == .connected
        return FleetDeviceSnapshot(
            device: FleetDeviceDescriptor(
                id: device.id,
                name: device.name,
                kind: device.isLocal ? .local : .remote,
                osID: device.osID
            ),
            connection: connection,
            snapshot: hasSnapshot ? deviceSessionSnapshot(device: device, model: model) : nil,
            availableAgentKinds: availableAgentKinds
        )
    }

    func deviceSessionSnapshot(device: Device, model: AppModel) -> SessionSnapshot {
        let state = model.session(device.id)
        let version: String?
        if case .connected(let value) = state.connection {
            version = value
        } else {
            version = nil
        }
        return .fleet(
            agents: state.agents,
            workspaces: state.workspaces,
            tabs: state.tabs,
            panes: state.panes,
            version: version,
            protocolVersion: HerdrService.minimumProtocolVersion
        )
    }

    func requiredString(
        _ params: [String: JSONValue],
        _ key: String
    ) throws -> String {
        guard let value = optionalString(params, key), !value.isEmpty else {
            throw FleetBridgeHostError.invalidRequest("Missing \(key).")
        }
        return value
    }

    func optionalString(
        _ params: [String: JSONValue],
        _ key: String
    ) -> String? {
        guard case .string(let value)? = params[key] else { return nil }
        return value
    }

    func optionalStrings(
        _ params: [String: JSONValue],
        _ key: String
    ) -> [String]? {
        guard case .array(let values)? = params[key] else { return nil }
        let strings = values.compactMap { value -> String? in
            guard case .string(let string) = value else { return nil }
            return string
        }
        return strings.count == values.count ? strings : nil
    }

    func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
