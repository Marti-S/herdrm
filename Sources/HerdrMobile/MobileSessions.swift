import Foundation
import HerdrKit
import HerdrSSH
import SwiftUI

enum MobileConnectionState: Equatable {
    case idle
    case connecting
    case connected(version: String)
    case failed(String)
    init(_ connection: FleetConnectionInfo) {
        switch connection.phase {
        case .idle: self = .idle
        case .connecting: self = .connecting
        case .connected: self = .connected(version: connection.version ?? "")
        case .failed: self = .failed(connection.message ?? String(localized: "Connection failed"))
        }
    }
    var isConnected: Bool { if case .connected = self { return true }; return false }
}

struct MobileDeviceEntry: Identifiable {
    enum Source: Equatable { case bridge, direct }
    let id: UUID
    let source: Source
    let name: String
    let subtitle: String
    let state: MobileConnectionState
    let snapshot: SessionSnapshot?
    let availableAgentKinds: [String]
}
struct MobileSpaceEntry: Identifiable {
    let ref: FleetSpaceRef
    let workspace: WorkspaceInfo
    let device: MobileDeviceEntry
    var id: FleetSpaceRef { ref }
}
struct MobileAgentEntry: Identifiable {
    let ref: FleetPaneRef
    let agent: AgentInfo
    let device: MobileDeviceEntry
    var id: FleetPaneRef { ref }
}
struct MobileTerminalEntry: Identifiable {
    let ref: FleetPaneRef
    let pane: PaneInfo
    let device: MobileDeviceEntry
    var id: FleetPaneRef { ref }
}

@MainActor
final class MobileDeviceSession {
    let device: MobileDevice
    var state: MobileConnectionState = .idle
    var snapshot: SessionSnapshot?
    private(set) var transport: MobileTransport?
    private(set) var transportID = UUID()
    var onChange: (() -> Void)?

    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var refreshTaskGeneration: UInt64 = 0
    private var refreshDirty = false
    private var generation: UInt64 = 0
    private var wantsConnection = false
    private var backoff: Double = 1
    private let clock = ContinuousClock()
    private var lastRefreshStart: ContinuousClock.Instant?

    init(device: MobileDevice) { self.device = device }

    func reconnect() async { await disconnect(); await connect() }

    func connect() async {
        wantsConnection = true
        switch state { case .connecting, .connected: return; case .idle, .failed: break }
        // Claim the connecting state before the first suspension point.
        state = .connecting
        generation &+= 1
        let expected = generation
        eventTask?.cancel()
        refreshTask?.cancel()
        refreshTaskGeneration &+= 1
        eventTask = nil
        refreshTask = nil
        refreshDirty = false
        lastRefreshStart = nil
        onChange?()
        if let stale = transport { transport = nil; await stale.close() }
        guard generation == expected, wantsConnection, !Task.isCancelled else { return }
        var candidate: SSHDirectTransport?
        do {
            let opened = try await SSHDirectTransport.connect(device: device)
            candidate = opened
            let pong = try await opened.request(method: "ping", params: .object([:]), as: PingResult.self)
            guard pong.protocolVersion >= 17 else { throw HerdrError.incompatibleProtocol(pong.protocolVersion) }
            guard generation == expected, wantsConnection, !Task.isCancelled else { await opened.close(); return }
            transport = opened
            transportID = UUID()
            candidate = nil
            backoff = 1
            state = .connected(version: pong.version)
            onChange?()
            startEventPump(transport: opened, generation: expected)
            await requestRefresh(generation: expected, debounce: false)
        } catch {
            if let candidate { await candidate.close() }
            guard generation == expected, wantsConnection, !Task.isCancelled else { return }
            state = .failed(Self.presentation(error))
            onChange?()
            if !Self.isPermanent(error) { scheduleReconnect() }
        }
    }

    func disconnect() async {
        wantsConnection = false
        generation &+= 1
        eventTask?.cancel()
        refreshTask?.cancel()
        reconnectTask?.cancel()
        eventTask = nil
        refreshTask = nil
        reconnectTask = nil
        refreshTaskGeneration &+= 1
        refreshDirty = false
        lastRefreshStart = nil
        let stale = transport
        transport = nil
        state = .idle
        onChange?()
        // No state mutation after this await can overwrite a newer connection.
        await stale?.close()
    }

    func refresh() async { await requestRefresh(generation: generation, debounce: false) }

    private func requestRefresh(generation expected: UInt64, debounce: Bool) async {
        guard generation == expected else { return }
        refreshDirty = true
        let task = refreshTask ?? startRefreshTask(generation: expected, debounce: debounce)
        await task.value
    }

    private func startRefreshTask(generation expected: UInt64, debounce: Bool) -> Task<Void, Never> {
        refreshTaskGeneration &+= 1
        let taskGeneration = refreshTaskGeneration
        let task = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(300)) }
            guard let self, !Task.isCancelled else { return }
            await self.runRefreshLoop(generation: expected, taskGeneration: taskGeneration)
        }
        refreshTask = task
        return task
    }

    private func runRefreshLoop(generation expected: UInt64, taskGeneration: UInt64) async {
        while !Task.isCancelled, generation == expected, refreshDirty {
            if let lastRefreshStart {
                do { try await clock.sleep(until: lastRefreshStart + .milliseconds(300)) }
                catch { break }
            }
            guard !Task.isCancelled, generation == expected else { break }
            refreshDirty = false
            lastRefreshStart = clock.now
            await performRefresh(generation: expected)
        }
        if refreshTaskGeneration == taskGeneration { refreshTask = nil }
    }

    private func performRefresh(generation expected: UInt64) async {
        guard let transport else { return }
        struct Envelope: Codable { let snapshot: SessionSnapshot }
        do {
            let next = try await transport.request(method: "session.snapshot", as: Envelope.self).snapshot
            guard generation == expected, !Task.isCancelled, snapshot != next else { return }
            snapshot = next
            onChange?()
        } catch {
            // Retain the last fleet state; the event stream owns liveness.
        }
    }

    private func startEventPump(transport: any MobileTransport, generation expected: UInt64) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            do {
                for try await _ in transport.events(kinds: HerdrEvent.allKinds) {
                    self?.scheduleRefresh(generation: expected)
                }
            } catch {}
            guard let self, !Task.isCancelled, self.generation == expected else { return }
            self.state = .failed(String(localized: "Connection lost"))
            let stale = self.transport
            self.transport = nil
            self.onChange?()
            await stale?.close()
            guard self.generation == expected else { return }
            self.scheduleReconnect()
        }
    }

    private func scheduleRefresh(generation expected: UInt64) {
        guard generation == expected else { return }
        refreshDirty = true
        guard refreshTask == nil else { return }
        _ = startRefreshTask(generation: expected, debounce: true)
    }

    private func scheduleReconnect() {
        guard wantsConnection, reconnectTask == nil else { return }
        let delay = backoff
        backoff = min(backoff * 2, 30)
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.wantsConnection, !Task.isCancelled else { return }
            self.reconnectTask = nil
            await self.connect()
        }
    }

    private static func isPermanent(_ error: any Error) -> Bool {
        if let error = error as? SSHError {
            switch error {
            case .authenticationFailed, .algorithmNegotiationFailed, .invalidEndpoint, .forwardingDenied: return true
            default: break
            }
        }
        if let error = error as? MobileTransportError {
            switch error { case .hostKeyChanged, .missingPassword: return true; default: break }
        }
        if let error = error as? HerdrError {
            if case .incompatibleProtocol = error { return true }
        }
        return false
    }

    private static func presentation(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
