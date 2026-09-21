#!/usr/bin/env python3
"""Bounded, local-only refused-quit regression.

Compile production fleet session/termination methods and bridge shutdown unchanged.
Substitute persistence/UI, snapshot/catalog/event payloads, and SSH with a local
cat byte-stream. Real startSession/reconnect, service.disconnect, tunnel.tearDown,
bridge timeout and delegate decision execute; no user sockets or SSH are used.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / 'Packages/HerdrKit/Sources/HerdrKit/Platform/macOS'
fleet = (ROOT / 'Sources/HerdrM/Runtime/Fleet/FleetStore.swift').read_text()


def method(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


prefix = r'''
import Foundation
import Darwin
struct SSHAuthenticationConfiguration {
 let arguments: [String] = []; let environment: [String:String] = [:]
 func discardAuthorization() {}
}
enum HerdrError: Error { case tunnelFailed(String), connectionFailed(String) }
struct Device { let id = UUID(); let isTailcat = false; let sshTarget: String? = nil }
enum ConnectionState: Equatable { case connecting, connected(version: String), failed(String) }
enum Catalog { case loading, failed(String) }
struct DeviceSessionState { var connection = ConnectionState.connecting; var agentCatalog = Catalog.loading }
enum FleetStateChange { case device(UUID) }
struct SSHAuthenticationRequest { let deviceID: UUID; let target: String }
struct HerdrEvent {
 let kind: String
 static let agentStatusChangedKind = "status", subscriptionStartedKind = "started"
}
actor TailcatBridgeManager {
 static let shared = TailcatBridgeManager()
 func tearDown(deviceID: UUID) {}
}
func check(_ value: Bool, _ message: String) {
 if !value { print("FAIL: \(message)"); fflush(stdout); exit(1) }
}
func socketClient(_ path: String) -> Int32 {
 let fd = socket(AF_UNIX, SOCK_STREAM, 0)
 var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
 withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
 let rc = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
 if rc != 0 { close(fd); return -1 }; return fd
}
func roundTrip(_ path: String) -> Bool {
 let fd = socketClient(path); guard fd >= 0 else { return false }; defer { close(fd) }
 var timeout = timeval(tv_sec: 2, tv_usec: 0)
 _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
 var noPipe: Int32 = 1
 _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
 var byte: UInt8 = 42
 guard write(fd, &byte, 1) == 1 else { return false }
 byte = 0
 return read(fd, &byte, 1) == 1 && byte == 42
}
final class Gate: @unchecked Sendable {
 let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
 func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 2) == .success }
 func block() {
  entered.signal()
  check(release.wait(timeout: .now() + 12) == .success, "launch gate exceeded fixture deadline")
 }
}
actor SSHTunnel {
 var process: Process?; var apiBridge: SSHRemoteAPIBridge?; var localSocketPath: String?
 init(_ bridge: SSHRemoteAPIBridge) { apiBridge = bridge; localSocketPath = bridge.localSocketPath }
 static func authenticationConfiguration(for id: UUID?) -> SSHAuthenticationConfiguration { .init() }
 func resetErrorCapture() {}
 static func targetIdentifier(for s: String) -> String { "fixture" }
 static func sshDestination(_ s: String) -> String { s }
 static func powershellEncodedCommand(_ s: String) -> String { s }
'''
tunnel = method((MAC / 'SSHTunnel.swift').read_text(), 'public func tearDown()')
service = r'''
}
actor HerdrService {
 let device: Device; let tunnel: SSHTunnel?; let bridge: SSHRemoteAPIBridge
 var connectCount = 0
 var rpc: Int?; var eventContinuation: AsyncThrowingStream<HerdrEvent, Error>.Continuation?
 init(device: Device, bridge: SSHRemoteAPIBridge) { self.device = device; self.bridge = bridge; tunnel = SSHTunnel(bridge) }
 struct Pong { let version = "fixture" }
 func connect() async throws -> Pong {
  connectCount += 1
  try bridge.start()
  guard roundTrip(bridge.localSocketPath) else { throw HerdrError.connectionFailed("fixture round-trip failed") }
  rpc = 1; return Pong()
 }
 func events(statusPaneIDs: [String]) throws -> AsyncThrowingStream<HerdrEvent, Error> {
  AsyncThrowingStream { eventContinuation = $0 }
 }
'''
disconnect = '@discardableResult\n' + method((MAC / 'HerdrService.swift').read_text(), 'public func disconnect()')
store = r'''
}
@MainActor final class FleetStore {
 var devices: [Device]; var devicesInScope: [Device] { devices }
 var services: [UUID: HerdrService] = [:], retiringServices: [HerdrService] = []
 var sessions: [UUID: DeviceSessionState] = [:]
 var sessionTasks: [UUID: Task<Void,Never>] = [:], refreshDebounces: [UUID: Task<Void,Never>] = [:], snapshotRefreshTasks: [UUID: Task<Void,Never>] = [:]
 var sessionTaskGenerations: [UUID: UInt64] = [:], refreshDebounceTokens: [UUID: UInt64] = [:], snapshotRefreshTokens: [UUID: UInt64] = [:], statusGenerations: [UUID: UInt64] = [:]
 var refreshDebouncePending: Set<UUID> = [], refreshRequested: Set<UUID> = []
 var previousStatuses: [UUID: Int] = [:]
 var hasStarted = true; var actionError: String?; var sshAuthenticationRequest: SSHAuthenticationRequest?
 var changes: [FleetStateChange] = []
 let makeService: (Device) -> HerdrService
 init(_ device: Device, makeService: @escaping (Device) -> HerdrService) { devices = [device]; self.makeService = makeService }
 func service(for device: Device) -> HerdrService {
  if let current = services[device.id] { return current }
  let service = makeService(device); services[device.id] = service; return service
 }
 func device(_ id: UUID) -> Device? { devices.first { $0.id == id } }
 func publishFleetChange(_ change: FleetStateChange) { changes.append(change) }
 func synchronizeSSHPlatform(deviceID: UUID, using: HerdrService) async -> Bool { true }
 func probeOSIfNeeded(_ device: Device) {}
 func refresh(_ id: UUID) async {}
 func loadAgentCatalog(deviceID: UUID, using: HerdrService) async {}
 func statusSubscriptionPaneIDs(_ id: UUID) -> [String] { [] }
 func applyAgentStatusEvent(_ event: HerdrEvent, deviceID: UUID) -> Bool { false }
 func scheduleRefresh(_ id: UUID) {}
 func refreshImmediately(_ id: UUID) async -> Bool { true }
 static let paneTopologyEventKinds: Set<String> = []
 func setAgentCatalog(_ catalog: Catalog, for id: UUID) {}
 func actionErrorMessage(_ error: Error, device: Device) -> String { error.localizedDescription }
 static func isSSHAuthenticationFailure(_ error: Error) -> Bool { false }
 func refreshNamedSessions() {}
'''
methods = '\n'.join(method(fleet, signature) for signature in [
    'func session(', 'private func setConnection(', 'private func isCurrentSessionTask(',
    'private func startSession(', 'func shutdownAllSessions(', 'private func stopSession(',
    'var hasReconnectableDevice:', 'func reconnectFailedDevices(', 'private func isFailed('
])
# AppKit is the external UI boundary; execute its actual delegate decision with a
# recording sender rather than terminating the test runner or the user's app.
delegate = method((ROOT / 'Sources/HerdrM/App/HerdrMApp.swift').read_text(), 'func applicationShouldTerminate(')
main = r'''
}
@MainActor final class NSApplication {
 enum TerminateReply { case terminateLater }
 var replies: [Bool] = []
 func reply(toApplicationShouldTerminate value: Bool) { replies.append(value) }
}
@MainActor final class AppDelegate {
 let model: FleetStore
 init(_ model: FleetStore) { self.model = model }
DELEGATE
}
@main struct Main {
 @MainActor static func until(_ message: String, _ condition: () -> Bool) async throws {
  let deadline = Date().addingTimeInterval(7)
  while !condition() {
   check(Date() < deadline, message)
   try await Task.sleep(nanoseconds: 10_000_000)
  }
 }
 @MainActor static func main() async throws {
  let path = CommandLine.arguments[1] + "/fleet.sock"
  let gate = Gate()
  func bridge(block: Bool) -> SSHRemoteAPIBridge {
   SSHRemoteAPIBridge(localSocketPath: path, target: "fixture", herdrExecutable: "unused", credentialID: nil,
    configureProcess: { p in
     if block { gate.block() }
     p.executableURL = URL(fileURLWithPath: "/bin/cat"); p.arguments = []
    }, makeAuthentication: { .init() })
  }
  let device = Device()
  let oldBridge = bridge(block: true)
  try oldBridge.start()
  let oldFD = socketClient(path); check(oldFD >= 0, "connect old fixture")
  defer { close(oldFD) }
  check(await Task.detached { gate.waitUntilEntered() }.value, "launch did not enter")
  weak var retired: HerdrService?
  let model = FleetStore(device) { HerdrService(device: $0, bridge: bridge(block: false)) }
  do {
   let old = HerdrService(device: device, bridge: oldBridge)
   retired = old; model.services[device.id] = old
  }
  model.sessions[device.id] = DeviceSessionState(connection: .connected(version: "old"))
  model.sessionTaskGenerations[device.id] = 1
  let app = NSApplication(), delegate = AppDelegate(model)
  let start = Date()
  check(delegate.applicationShouldTerminate(app) == .terminateLater, "delegate must defer reply")
  try await until("no bounded quit reply") { !app.replies.isEmpty }
  check(app.replies == [false], "bridge timeout must refuse quit")
  check(Date().timeIntervalSince(start) >= 3.5, "must exercise real bridge timeout")
  check(retired != nil && model.retiringServices.count == 1, "timed-out service ownership lost")
  check(model.session(device.id).connection != .connected(version: "old"), "refused quit left stale connected state")
  check(model.sessionTaskGenerations[device.id] == 2, "shutdown must fence old task generations without resetting them")
  check(model.hasReconnectableDevice, "stopped device must be reconnectable")
  check(!model.changes.isEmpty, "stopped connection must invalidate semantic fleet cache")
  check(model.actionError?.isEmpty == false, "refused quit needs actionable UI error")
  // Begin recovery while the old launch is STILL blocked. Connecting before its
  // stop finishes could let old cleanup unlink a newly bound same-path listener.
  model.reconnectFailedDevices()
  try await Task.sleep(nanoseconds: 100_000_000)
  check(model.retiringServices.count == 1 && retired != nil, "reconnect discarded retiring owner")
  check(await model.services[device.id]!.connectCount == 0, "reconnect raced unfinished retiring teardown")
  var oldForRetry: HerdrService? = retired
  gate.release.signal()
  try await until("reconnect did not recover") { model.session(device.id).connection == .connected(version: "fixture") }
  check(roundTrip(path), "recovered listener cannot serve requests")
  check(await oldForRetry!.disconnect(), "retiring disconnect retry failed")
  oldForRetry = nil
  check(roundTrip(path), "retiring cleanup unlinked replacement listener")
  check(delegate.applicationShouldTerminate(app) == .terminateLater, "retry must defer reply")
  try await until("quit retry did not complete") { app.replies.count == 2 }
  check(app.replies == [false, true], "quit retry should succeed after recovery")
  check(model.retiringServices.isEmpty && retired == nil, "successful retry retained old service")
  check(!FileManager.default.fileExists(atPath: path), "successful quit left replacement socket")
  print("PASS: timeout refuses quit; semantic failure/error enables reconnect; real fleet loop recovers over local bridge; retiring retry preserves replacement; next quit succeeds")
 }
}
'''.replace('DELEGATE', delegate)
with tempfile.TemporaryDirectory(prefix='herdr-refused-', dir='/tmp') as directory:
    out = Path(directory)
    bridge = (MAC / 'SSHRemoteAPIBridge.swift').read_text().replace(
        'FileManager.default.temporaryDirectory', 'URL(fileURLWithPath: CommandLine.arguments[1])')
    source = prefix + tunnel + service + disconnect + store + methods + main + bridge
    (out / 'Fixture.swift').write_text(source)
    subprocess.run(['swiftc', '-parse-as-library', str(out / 'Fixture.swift'), '-o', str(out / 'fixture')], check=True, timeout=60)
    subprocess.run([str(out / 'fixture'), directory], check=True, timeout=25)
