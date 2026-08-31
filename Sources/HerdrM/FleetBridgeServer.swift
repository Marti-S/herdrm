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

/// In-process host for the Mac-owned fleet. It listens on loopback by default;
/// Tailscale can expose the fixed TCP port without moving SSH credentials or
/// remote-device configuration onto the phone.
@MainActor
final class FleetBridgeServer {
    static let shared = FleetBridgeServer()

    private let networkQueue = DispatchQueue(label: "dev.bybee.herdrm.fleet-bridge.network")
    weak var model: AppModel?
    private var listener: NWListener?
    private var connections: [UUID: FleetBridgeServerConnection] = [:]
    private var subscriptions: [UUID: FleetBridgeServerConnection] = [:]
    private var modelCancellable: AnyCancellable?
    private var publishTask: Task<Void, Never>?
    private var revision: UInt64 = 1
    private var token = ""
    private var configuration = FleetBridgeHostConfiguration.load()

    private init() {}

    func start(model: AppModel) {
        self.model = model
        configuration = .load()
        do {
            token = try FleetBridgeCredentialStore.token()
            try FleetBridgeCredentialStore.writePairingInfo(
                configuration: configuration,
                serverName: serverName
            )
        } catch {
            fleetBridgeLog.error("bridge credentials unavailable: \(error.localizedDescription)")
            return
        }

        modelCancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.schedulePublish() }
        }

        guard configuration.enabled else {
            fleetBridgeLog.notice("mobile bridge disabled by user defaults")
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            let port = NWEndpoint.Port(rawValue: configuration.port)!
            if !configuration.bindAllInterfaces {
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: port
                )
            }
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        fleetBridgeLog.notice("mobile bridge listening on port \(self.configuration.port)")
                    case .failed(let error):
                        fleetBridgeLog.error("mobile bridge listener failed: \(error.localizedDescription)")
                        self.listener?.cancel()
                        self.listener = nil
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: networkQueue)
        } catch {
            fleetBridgeLog.error("could not start mobile bridge: \(error.localizedDescription)")
        }
    }

    func stop() {
        publishTask?.cancel()
        publishTask = nil
        modelCancellable?.cancel()
        modelCancellable = nil
        for connection in Array(connections.values) {
            connection.close()
        }
        connections.removeAll()
        subscriptions.removeAll()
        listener?.cancel()
        listener = nil
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

        let hasSnapshot = !state.agents.isEmpty
            || !state.workspaces.isEmpty
            || !state.tabs.isEmpty
            || !state.panes.isEmpty
            || connection.phase == .connected
        return FleetDeviceSnapshot(
            device: FleetDeviceDescriptor(
                id: device.id,
                name: device.name,
                subtitle: device.subtitle,
                isLocal: device.isLocal,
                osID: device.osID
            ),
            connection: connection,
            snapshot: hasSnapshot ? deviceSessionSnapshot(device: device, model: model) : nil
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
