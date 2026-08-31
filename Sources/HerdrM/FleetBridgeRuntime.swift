import Combine
import Foundation
import HerdrKit
import os

@MainActor
final class FleetBridgeRuntime {
    static let shared = FleetBridgeRuntime()

    private static let bridgeIDKey = "fleet.bridge.id"
    private let logger = Logger(subsystem: "dev.bybee.herdrm", category: "fleet-bridge")

    private weak var model: AppModel?
    private var router: FleetBridgeRequestRouter?
    private var host: FleetBridgeHost?
    private var unixServer: FleetBridgeUnixServer?
    private var changes: AnyCancellable?
    private var publishTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var revision: UInt64 = 0

    private init() {}

    func start(model: AppModel) {
        guard host == nil,
              ProcessInfo.processInfo.environment["HERDRM_DISABLE_FLEET_BRIDGE"] != "1"
        else { return }

        self.model = model
        revision = 1
        let router = FleetBridgeRequestRouter(model: model)
        let host = FleetBridgeHost(
            bridgeID: Self.bridgeID(),
            bridgeName: ProcessInfo.processInfo.hostName,
            capabilities: [.observe, .control],
            initialSnapshot: model.fleetSnapshot(revision: revision),
            requestHandler: { [weak router] request in
                guard let router else {
                    return .failure(
                        id: request.id,
                        error: FleetRPCError(
                            code: "bridge_stopped",
                            message: "The Mac fleet bridge is stopping.",
                            retryable: true
                        )
                    )
                }
                return await router.handle(request)
            }
        )
        let unixServer = FleetBridgeUnixServer(host: host)
        self.router = router
        self.host = host
        self.unixServer = unixServer

        changes = Publishers.Merge(
            model.$devices.dropFirst().map { _ in () },
            model.$sessions.dropFirst().map { _ in () }
        )
        .sink { [weak self] in
            Task { @MainActor in self?.schedulePublish() }
        }

        startupTask = Task { [weak self, unixServer] in
            do {
                try await unixServer.start()
                guard !Task.isCancelled else {
                    await unixServer.stop()
                    return
                }
                self?.logger.info(
                    "fleet bridge listening at \(unixServer.socketPath)"
                )
            } catch is CancellationError {
                await unixServer.stop()
            } catch {
                self?.logger.error(
                    "fleet bridge failed to start: \(error.localizedDescription)"
                )
                await unixServer.stop()
                self?.clearStoppedServer(unixServer)
            }
        }
    }

    func stop() async {
        publishTask?.cancel()
        publishTask = nil
        let startup = startupTask
        startup?.cancel()
        startupTask = nil
        changes = nil

        let server = unixServer
        unixServer = nil
        host = nil
        router = nil
        model = nil
        await server?.stop()
        _ = await startup?.result
    }

    private func schedulePublish() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            // Published values emit before their mutation is externally
            // observable. Coalescing also collapses event-driven snapshot bursts.
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled,
                  let model = self.model,
                  let host = self.host
            else { return }

            self.revision &+= 1
            let snapshot = model.fleetSnapshot(revision: self.revision)
            _ = await host.publish(snapshot)
        }
    }

    private func clearStoppedServer(_ server: FleetBridgeUnixServer) {
        guard unixServer === server else { return }
        changes = nil
        startupTask = nil
        unixServer = nil
        host = nil
        router = nil
        model = nil
    }

    private static func bridgeID(defaults: UserDefaults = .standard) -> UUID {
        if let raw = defaults.string(forKey: bridgeIDKey),
           let existing = UUID(uuidString: raw) {
            return existing
        }
        let created = UUID()
        defaults.set(created.uuidString, forKey: bridgeIDKey)
        return created
    }
}

@MainActor
private final class FleetBridgeRequestRouter {
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func handle(_ request: FleetRPCRequest) async -> FleetRPCResponse {
        guard let model else {
            return failure(
                request,
                code: "bridge_stopped",
                message: "The Mac fleet bridge is stopping.",
                retryable: true
            )
        }
        guard let device = model.device(request.deviceID) else {
            return failure(
                request,
                code: "device_not_found",
                message: "The requested device is no longer configured."
            )
        }

        do {
            let params = try objectParams(request)
            let service = model.service(for: device)
            switch request.method {
            case "agent.prompt":
                try await service.prompt(
                    target: try string("target", in: params),
                    text: try string("text", in: params)
                )
            case "pane.send_input":
                let paneID = try string("pane_id", in: params)
                let text = params["text"]?.stringValue
                let keys = try stringArrayIfPresent("keys", in: params)
                guard (text == nil) != (keys == nil) else {
                    throw RoutingError.invalidParameters(
                        "pane.send_input requires exactly one of text or keys"
                    )
                }
                if let text {
                    try await service.sendInput(paneID: paneID, text: text)
                } else {
                    try await service.sendKeys(paneID: paneID, keys: keys ?? [])
                }
            default:
                return failure(
                    request,
                    code: "method_not_allowed",
                    message: "The Mac fleet bridge does not allow \(request.method)."
                )
            }
            return .success(id: request.id)
        } catch let error as RoutingError {
            return failure(
                request,
                code: "invalid_params",
                message: error.localizedDescription
            )
        } catch let error as HerdrError {
            if case .rpc(let code, let message) = error {
                return failure(request, code: code, message: message)
            }
            return failure(
                request,
                code: "request_failed",
                message: error.localizedDescription,
                retryable: Self.isRetryable(error)
            )
        } catch {
            return failure(
                request,
                code: "request_failed",
                message: error.localizedDescription
            )
        }
    }

    private enum RoutingError: LocalizedError {
        case invalidParameters(String)

        var errorDescription: String? {
            switch self {
            case .invalidParameters(let detail): return detail
            }
        }
    }

    private func objectParams(
        _ request: FleetRPCRequest
    ) throws -> [String: JSONValue] {
        guard case .object(let params) = request.params else {
            throw RoutingError.invalidParameters("params must be an object")
        }
        return params
    }

    private func string(
        _ key: String,
        in params: [String: JSONValue]
    ) throws -> String {
        guard let value = params[key]?.stringValue else {
            throw RoutingError.invalidParameters("\(key) must be a string")
        }
        return value
    }

    private func stringArrayIfPresent(
        _ key: String,
        in params: [String: JSONValue]
    ) throws -> [String]? {
        guard let value = params[key] else { return nil }
        guard case .array(let values) = value else {
            throw RoutingError.invalidParameters("\(key) must be an array")
        }
        let strings = values.compactMap(\.stringValue)
        guard strings.count == values.count else {
            throw RoutingError.invalidParameters("\(key) must contain only strings")
        }
        return strings
    }

    private func failure(
        _ request: FleetRPCRequest,
        code: String,
        message: String,
        retryable: Bool = false
    ) -> FleetRPCResponse {
        .failure(
            id: request.id,
            error: FleetRPCError(
                code: code,
                message: message,
                retryable: retryable
            )
        )
    }

    private static func isRetryable(_ error: HerdrError) -> Bool {
        switch error {
        case .socketUnavailable, .connectionFailed, .tunnelFailed,
             .remoteHerdrDown:
            return true
        default:
            return false
        }
    }
}
