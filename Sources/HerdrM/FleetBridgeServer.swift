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

    private struct FleetCache {
        let snapshot: FleetSnapshot
        let encodedSnapshot: Data
    }

    private let networkQueue = DispatchQueue(label: "dev.bybee.herdrm.fleet-bridge.network")
    weak var model: AppModel?
    private var listener: NWListener?
    private var listenerID: ObjectIdentifier?
    private var pathMonitor: NWPathMonitor?
    private var pathMonitorGeneration = UUID()
    private var availableNetworkInterfaces: [NWInterface] = []
    private var interfaceRefreshTask: Task<Void, Never>?
    private var listenerRetryTask: Task<Void, Never>?
    private var connections: [UUID: FleetBridgeServerConnection] = [:]
    private var subscriptions: [UUID: FleetBridgeServerConnection] = [:]
    private var modelCancellable: AnyCancellable?
    private var publishTask: Task<Void, Never>?
    private var revision: UInt64 = 1
    private var lastBroadcastRevision: UInt64 = 1
    private var dirtyDeviceIDs: Set<UUID> = []
    private var rebuildEntireFleet = false
    private var cachedDevicesByID: [UUID: FleetDeviceSnapshot] = [:]
    private var cachedDeviceOrder: [UUID] = []
    private var fleetCache: FleetCache?
    private var suppressedFleetUpdates: UInt64 = 0
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
        modelCancellable = model.fleetStateDidChange.sink { [weak self] change in
            Task { @MainActor in self?.schedulePublish(change) }
        }
        do {
            let cache = try refreshFleetCacheIfNeeded(
                force: true,
                incrementRevision: false
            )
            lastBroadcastRevision = cache.snapshot.revision
        } catch {
            fleetBridgeLog.error(
                "could not initialize fleet snapshot cache: \(error.localizedDescription)"
            )
        }

        if configuration.enabled {
            startNetworkMonitoring()
        }
        reconcileListener(force: true)

        guard configuration.enabled else {
            fleetBridgeLog.notice("mobile bridge disabled by user defaults")
            return
        }
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
        availableNetworkInterfaces = []

        modelCancellable?.cancel()
        modelCancellable = nil
        dirtyDeviceIDs.removeAll()
        rebuildEntireFleet = false
        cachedDevicesByID.removeAll()
        cachedDeviceOrder.removeAll()
        fleetCache = nil

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
        try currentFleetCache().snapshot
    }

    func encodedSnapshot() throws -> Data {
        try currentFleetCache().encodedSnapshot
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
            switch identity.scope {
            case .tailscale:
                guard let interfaceName = identity.interfaceName,
                      let requiredInterface = availableNetworkInterfaces.first(where: {
                          $0.name == interfaceName
                      })
                else {
                    // NWInterface values come from NWPathMonitor asynchronously.
                    // Do not widen exposure while waiting for the selected tunnel.
                    scheduleListenerRetry()
                    return
                }
                parameters.requiredInterface = requiredInterface
                // Constraining the IP family keeps this an IPv4 listener on the
                // interface that owns the exact address exported for pairing.
                if let ip = parameters.defaultProtocolStack.internetProtocol
                    as? NWProtocolIP.Options {
                    ip.version = .v4
                }
            case .loopback:
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host(identity.bindHost ?? "127.0.0.1"),
                    port: .any
                )
            case .allInterfaces:
                break
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
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, self.pathMonitorGeneration == generation else { return }
                self.availableNetworkInterfaces = path.availableInterfaces
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

    private func schedulePublish(_ change: FleetStateChange) {
        switch change {
        case .device(let deviceID):
            dirtyDeviceIDs.insert(deviceID)
        case .topology:
            rebuildEntireFleet = true
        }

        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            self.publishTask = nil
            self.publishPendingFleetChanges()
        }
    }

    private func publishPendingFleetChanges() {
        do {
            let cache = try currentFleetCache()
            guard cache.snapshot.revision > lastBroadcastRevision else { return }
            lastBroadcastRevision = cache.snapshot.revision
            for connection in subscriptions.values {
                connection.sendSubscribedSnapshot(
                    encodedSnapshot: cache.encodedSnapshot
                )
            }
            fleetBridgeLog.debug(
                "published fleet revision \(cache.snapshot.revision) (\(cache.encodedSnapshot.count) bytes) to \(self.subscriptions.count) subscribers"
            )
        } catch {
            fleetBridgeLog.error(
                "could not publish fleet snapshot: \(error.localizedDescription)"
            )
        }
    }

    private func currentFleetCache() throws -> FleetCache {
        if fleetCache == nil || rebuildEntireFleet || !dirtyDeviceIDs.isEmpty {
            return try refreshFleetCacheIfNeeded()
        }
        guard let fleetCache else {
            throw FleetBridgeHostError.invalidRequest("HerdrM is not ready.")
        }
        return fleetCache
    }

    @discardableResult
    private func refreshFleetCacheIfNeeded(
        force: Bool = false,
        incrementRevision: Bool = true
    ) throws -> FleetCache {
        guard let model else {
            throw FleetBridgeHostError.invalidRequest("HerdrM is not ready.")
        }

        let deviceOrder = model.devices.map(\.id)
        let rebuildAll = force
            || fleetCache == nil
            || rebuildEntireFleet
            || cachedDeviceOrder != deviceOrder
        var nextDevicesByID = cachedDevicesByID
        if rebuildAll {
            nextDevicesByID.removeAll(keepingCapacity: true)
            for device in model.devices {
                nextDevicesByID[device.id] = deviceSnapshot(device: device, model: model)
            }
        } else {
            for deviceID in dirtyDeviceIDs {
                guard let device = model.device(deviceID) else {
                    nextDevicesByID.removeValue(forKey: deviceID)
                    continue
                }
                nextDevicesByID[deviceID] = deviceSnapshot(device: device, model: model)
            }
        }

        let devices = deviceOrder.compactMap { nextDevicesByID[$0] }
        dirtyDeviceIDs.removeAll()
        rebuildEntireFleet = false
        cachedDevicesByID = nextDevicesByID
        cachedDeviceOrder = deviceOrder

        if !force,
           let fleetCache,
           fleetCache.snapshot.devices == devices {
            suppressedFleetUpdates &+= 1
            fleetBridgeLog.debug(
                "suppressed unchanged fleet update (total \(self.suppressedFleetUpdates))"
            )
            return fleetCache
        }

        if incrementRevision, fleetCache != nil {
            revision &+= 1
        }
        let snapshot = FleetSnapshot(revision: revision, devices: devices)
        let encodedSnapshot = try JSONEncoder().encode(snapshot)
        let nextCache = FleetCache(
            snapshot: snapshot,
            encodedSnapshot: encodedSnapshot
        )
        fleetCache = nextCache
        return nextCache
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
