from __future__ import annotations

from pathlib import Path
import re

ROOT = Path.cwd()


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, value: str) -> None:
    (ROOT / path).write_text(value, encoding="utf-8")


def replace_once(value: str, old: str, new: str, label: str) -> str:
    count = value.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return value.replace(old, new, 1)


def regex_once(value: str, pattern: str, replacement: str, label: str) -> str:
    result, count = re.subn(pattern, replacement, value, count=1, flags=re.S)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return result


wire_path = "Packages/HerdrKit/Sources/HerdrKit/FleetBridgeWire.swift"
if "FleetBridgeEncodedSnapshot" in read(wire_path):
    print("Optimization already present; validation will run without reapplying it.")
    raise SystemExit(0)

# FleetBridge wire: encode typed envelopes directly and cache snapshot JSON.
text = read(wire_path)
text = replace_once(
    text,
    "public enum FleetBridgeWire {\n",
    """public struct FleetBridgeEncodedSnapshot: Sendable {
    fileprivate let data: Data

    public init(_ snapshot: FleetSnapshot) throws {
        data = try JSONEncoder().encode(snapshot)
    }
}

public enum FleetBridgeWire {
""",
    "encoded snapshot type",
)
text = regex_once(
    text,
    r"    public static func decodeClient\(_ data: Data\) throws -> FleetBridgeClientRecord \{.*?\n    \}\n\n(?=    public static func encodeServer)",
    """    public static func decodeClient(_ data: Data) throws -> FleetBridgeClientRecord {
        let envelope = try recordType(in: data)
        switch envelope.type {
        case "bridge.hello": return .hello(try decode(FleetBridgeHello.self, from: envelope.data))
        case "bridge.authenticate": return .authenticate(try decode(FleetBridgeAuthentication.self, from: envelope.data))
        case "fleet.snapshot": return .snapshot(try decode(FleetBridgeSnapshotRequest.self, from: envelope.data))
        case "fleet.subscribe": return .subscribe(try decode(FleetBridgeSubscribeRequest.self, from: envelope.data))
        case "herdr.request": return .rpc(try decode(FleetBridgeRPCRequest.self, from: envelope.data))
        case "terminal.open": return .terminalOpen(try decode(FleetBridgeTerminalOpenRequest.self, from: envelope.data))
        case "terminal.input": return .terminalInput(try decode(FleetBridgeTerminalInput.self, from: envelope.data))
        case "terminal.resize": return .terminalResize(try decode(FleetBridgeTerminalResize.self, from: envelope.data))
        case "terminal.release": return .terminalRelease(try decode(FleetBridgeTerminalRelease.self, from: envelope.data))
        default: throw FleetBridgeWireError.unsupportedRecordType(envelope.type)
        }
    }

""",
    "client decoder",
)
text = regex_once(
    text,
    r"    public static func decodeServer\(_ data: Data\) throws -> FleetBridgeServerRecord \{.*?\n    \}\n\n(?=    private static func line)",
    """    public static func decodeServer(_ data: Data) throws -> FleetBridgeServerRecord {
        let envelope = try recordType(in: data)
        switch envelope.type {
        case "bridge.challenge": return .challenge(try decode(FleetBridgeChallenge.self, from: envelope.data))
        case "bridge.welcome": return .welcome(try decode(FleetBridgeWelcome.self, from: envelope.data))
        case "fleet.snapshot": return .snapshot(try decode(FleetBridgeSnapshotRecord.self, from: envelope.data))
        case "herdr.response": return .rpc(try decode(FleetBridgeRPCResponse.self, from: envelope.data))
        case "terminal.frame": return .terminalFrame(try decode(FleetBridgeTerminalFrameRecord.self, from: envelope.data))
        case "terminal.closed": return .terminalClosed(try decode(FleetBridgeTerminalClosedRecord.self, from: envelope.data))
        case "bridge.error": return .error(try decode(FleetBridgeErrorRecord.self, from: envelope.data))
        default: throw FleetBridgeWireError.unsupportedRecordType(envelope.type)
        }
    }

    public static func encodeServerSnapshot(
        requestID: UUID,
        snapshot: FleetBridgeEncodedSnapshot
    ) throws -> Data {
        let encodedRequestID = try JSONEncoder().encode(requestID)
        var data = Data(#"{"type":"fleet.snapshot","payload":{"request_id":"#.utf8)
        data.append(encodedRequestID)
        data.append(Data(#",\"snapshot\":"#.utf8))
        data.append(snapshot.data)
        data.append(Data(#"}}"#.utf8))
        data.append(0x0A)
        return data
    }

""",
    "server decoder",
)
text = regex_once(
    text,
    r"    private static func line<T: Encodable>\(type: String, payload: T\) throws -> Data \{.*?\n    private struct Envelope: Decodable \{\n        let type: String\n        let payload: JSONValue\n    \}\n",
    """    private static func line<T: Encodable>(type: String, payload: T) throws -> Data {
        try JSONEncoder().encode(EncodingEnvelope(type: type, payload: payload)) + Data([0x0A])
    }

    private static func recordType(in data: Data) throws -> (type: String, data: Data) {
        let line = try normalizedRecordData(data)
        do {
            let envelope = try JSONDecoder().decode(RecordTypeEnvelope.self, from: line)
            return (envelope.type, line)
        } catch {
            throw FleetBridgeWireError.invalidRecord(error.localizedDescription)
        }
    }

    private static func normalizedRecordData(_ data: Data) throws -> Data {
        var line = data
        if line.last == 0x0A { line.removeLast() }
        if line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty else { throw FleetBridgeWireError.emptyRecord }
        return line
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(DecodingEnvelope<T>.self, from: data).payload
        } catch {
            throw FleetBridgeWireError.invalidRecord(error.localizedDescription)
        }
    }

    private struct EncodingEnvelope<Payload: Encodable>: Encodable {
        let type: String
        let payload: Payload
    }

    private struct RecordTypeEnvelope: Decodable {
        let type: String
    }

    private struct DecodingEnvelope<Payload: Decodable>: Decodable {
        let payload: Payload
    }
""",
    "wire helpers",
)
write(wire_path, text)

# Wire test for one encoded snapshot body reused by different request IDs.
test_path = "Packages/HerdrKit/Tests/HerdrKitTests/FleetBridgeWireTests.swift"
text = read(test_path)
text = replace_once(
    text,
    "    func testRemoteDescriptorContainsNoEndpointMetadata() throws {",
    """    func testEncodedSnapshotBodyCanBeReusedAcrossRequestIDs() throws {
        let snapshot = FleetSnapshot(
            revision: 91,
            devices: [
                FleetDeviceSnapshot(
                    device: FleetDeviceDescriptor(
                        id: UUID(), name: "Mac", kind: .local, osID: "macos"
                    ),
                    connection: .connected(version: "0.9.0"),
                    snapshot: nil,
                    availableAgentKinds: ["codex"]
                )
            ]
        )
        let cached = try FleetBridgeEncodedSnapshot(snapshot)
        let firstID = UUID()
        let secondID = UUID()
        let first = try FleetBridgeWire.encodeServerSnapshot(requestID: firstID, snapshot: cached)
        let second = try FleetBridgeWire.encodeServerSnapshot(requestID: secondID, snapshot: cached)
        XCTAssertEqual(
            try FleetBridgeWire.decodeServer(first),
            .snapshot(FleetBridgeSnapshotRecord(requestID: firstID, snapshot: snapshot))
        )
        XCTAssertEqual(
            try FleetBridgeWire.decodeServer(second),
            .snapshot(FleetBridgeSnapshotRecord(requestID: secondID, snapshot: snapshot))
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(first.dropLast())) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "fleet.snapshot")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["request_id"] as? String, firstID.uuidString)
        XCTAssertNotNil(payload["snapshot"] as? [String: Any])
    }

    func testRemoteDescriptorContainsNoEndpointMetadata() throws {""",
    "snapshot encoding test",
)
write(test_path, text)

# macOS snapshot refresh single-flight coordination.
path = "Sources/HerdrM/AppModel.swift"
text = read(path)
text = replace_once(
    text,
    """    private let store = DeviceStore()
    private var services: [UUID: HerdrService] = [:]
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshDebounces: [UUID: Task<Void, Never>] = [:]
    private var previousStatuses: [UUID: [String: AgentStatus]] = [:]
""",
    """    private struct RefreshWorker {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let store = DeviceStore()
    private var services: [UUID: HerdrService] = [:]
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshDebounces: [UUID: Task<Void, Never>] = [:]
    private var refreshWorkers: [UUID: RefreshWorker] = [:]
    private var refreshRequests: Set<UUID> = []
    private var previousStatuses: [UUID: [String: AgentStatus]] = [:]
""",
    "macOS refresh properties",
)
text = replace_once(
    text,
    """        sessionTasks.values.forEach { $0.cancel() }
        sessionTasks.removeAll()
        for service in live.values {
""",
    """        sessionTasks.values.forEach { $0.cancel() }
        sessionTasks.removeAll()
        refreshDebounces.values.forEach { $0.cancel() }
        refreshDebounces.removeAll()
        refreshWorkers.values.forEach { $0.task.cancel() }
        refreshWorkers.removeAll()
        refreshRequests.removeAll()
        for service in live.values {
""",
    "macOS shutdown refresh workers",
)
text = replace_once(
    text,
    """        refreshDebounces[id]?.cancel()
        refreshDebounces[id] = nil
        previousStatuses[id] = nil
""",
    """        refreshDebounces[id]?.cancel()
        refreshDebounces[id] = nil
        refreshWorkers[id]?.task.cancel()
        refreshWorkers[id] = nil
        refreshRequests.remove(id)
        previousStatuses[id] = nil
""",
    "macOS stop refresh worker",
)
match = re.search(r"    func refresh\(_ deviceID: UUID\) async \{\n(?P<body>.*?)\n    \}\n\n    private func scheduleRefresh", text, re.S)
if not match:
    raise RuntimeError("macOS refresh function not found")
body = match.group("body")
body = replace_once(
    body,
    "            let snapshot = try await service.snapshot()\n",
    "            let snapshot = try await service.snapshot()\n            guard !Task.isCancelled else { return }\n",
    "macOS refresh cancellation",
)
body = body.replace(
    "            sessions[deviceID]?.workspaces = snapshot.workspaces\n            sessions[deviceID]?.workspaces = snapshot.workspaces\n",
    "            sessions[deviceID]?.workspaces = snapshot.workspaces\n",
    1,
)
body = body.replace(
    "        } catch {\n            sessions[deviceID]?.connection = .failed(error.localizedDescription)\n",
    "        } catch {\n            guard !Task.isCancelled else { return }\n            sessions[deviceID]?.connection = .failed(error.localizedDescription)\n",
    1,
)
replacement = """    func refresh(_ deviceID: UUID) async {
        refreshRequests.insert(deviceID)
        if let worker = refreshWorkers[deviceID] {
            await worker.task.value
            return
        }
        let workerID = UUID()
        let task = Task { [weak self] in
            await self?.drainRefreshRequests(deviceID, workerID: workerID)
        }
        refreshWorkers[deviceID] = RefreshWorker(id: workerID, task: task)
        await task.value
    }

    private func drainRefreshRequests(_ deviceID: UUID, workerID: UUID) async {
        defer {
            if refreshWorkers[deviceID]?.id == workerID {
                refreshWorkers[deviceID] = nil
            }
        }
        while !Task.isCancelled, refreshRequests.remove(deviceID) != nil {
            await performRefresh(deviceID)
        }
    }

    private func performRefresh(_ deviceID: UUID) async {
""" + body + """
    }

    private func scheduleRefresh"""
text = text[:match.start()] + replacement + text[match.end():]
write(path, text)

# Fleet bridge semantic deduplication and encoded snapshot cache.
path = "Sources/HerdrM/FleetBridgeServer.swift"
text = read(path)
text = replace_once(
    text,
    """    private var modelCancellable: AnyCancellable?
    private var publishTask: Task<Void, Never>?
    private var revision: UInt64 = 1
    private var token = ""
""",
    """    private var modelCancellable: AnyCancellable?
    private var publishTask: Task<Void, Never>?
    private var snapshotDirty = true
    private var cachedSnapshot: FleetSnapshot?
    private var cachedSnapshotEncoding: (revision: UInt64, value: FleetBridgeEncodedSnapshot)?
    private var lastBroadcastRevision: UInt64?
    private var revision: UInt64 = 1
    private var token = ""
""",
    "bridge cache properties",
)
text = replace_once(text, "        configuration = .load()\n", "        configuration = .load()\n        snapshotDirty = true\n        lastBroadcastRevision = nil\n", "bridge dirty start")
text = replace_once(
    text,
    """        modelCancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.schedulePublish() }
        }
""",
    """        modelCancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.snapshotDirty = true
                self?.schedulePublish()
            }
        }
""",
    "bridge change sink",
)
text = replace_once(text, "        subscriptions.removeAll()\n    }\n", "        subscriptions.removeAll()\n        lastBroadcastRevision = nil\n    }\n", "bridge stop reset")
text = replace_once(
    text,
    """    func snapshot() throws -> FleetSnapshot {
        guard let model else {
            throw FleetBridgeHostError.invalidRequest("HerdrM is not ready.")
        }
        return FleetSnapshot(
            revision: revision,
            devices: model.devices.map { deviceSnapshot(device: $0, model: model) }
        )
    }
""",
    """    func snapshot() throws -> FleetSnapshot {
        if !snapshotDirty, let cachedSnapshot { return cachedSnapshot }
        guard let model else {
            throw FleetBridgeHostError.invalidRequest("HerdrM is not ready.")
        }
        let devices = model.devices.map { deviceSnapshot(device: $0, model: model) }
        snapshotDirty = false
        if let cachedSnapshot, cachedSnapshot.devices == devices { return cachedSnapshot }
        if cachedSnapshot != nil { revision &+= 1 }
        let snapshot = FleetSnapshot(revision: revision, devices: devices)
        cachedSnapshot = snapshot
        cachedSnapshotEncoding = nil
        return snapshot
    }

    func encodedSnapshotRecord(requestID: UUID, snapshot: FleetSnapshot) throws -> Data {
        let encoded: FleetBridgeEncodedSnapshot
        if let cachedSnapshotEncoding, cachedSnapshotEncoding.revision == snapshot.revision {
            encoded = cachedSnapshotEncoding.value
        } else {
            encoded = try FleetBridgeEncodedSnapshot(snapshot)
            cachedSnapshotEncoding = (snapshot.revision, encoded)
        }
        return try FleetBridgeWire.encodeServerSnapshot(requestID: requestID, snapshot: encoded)
    }
""",
    "bridge snapshot cache",
)
text = replace_once(
    text,
    """    private func schedulePublish() {
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
""",
    """    private func schedulePublish() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled,
                  let snapshot = try? self.snapshot(),
                  self.lastBroadcastRevision != snapshot.revision
            else { return }
            self.lastBroadcastRevision = snapshot.revision
            for connection in self.subscriptions.values {
                connection.sendSubscribedSnapshot(snapshot)
            }
        }
    }
""",
    "bridge semantic publish",
)
write(path, text)

path = "Sources/HerdrM/FleetBridgeServerConnection.swift"
text = read(path)
text = replace_once(text, "    private var handshakeTimeout: Task<Void, Never>?\n", "    private var handshakeTimeout: Task<Void, Never>?\n    private var lastSubscribedSnapshotRevision: UInt64?\n", "connection revision")
text = replace_once(
    text,
    """    func sendSubscribedSnapshot(_ snapshot: FleetSnapshot) {
        guard case .subscribed(let requestID) = stage else { return }
        send(.snapshot(FleetBridgeSnapshotRecord(
            requestID: requestID,
            snapshot: snapshot
        )))
    }
""",
    """    func sendSubscribedSnapshot(_ snapshot: FleetSnapshot) {
        guard case .subscribed(let requestID) = stage,
              lastSubscribedSnapshotRevision != snapshot.revision
        else { return }
        do {
            let data = try server.encodedSnapshotRecord(requestID: requestID, snapshot: snapshot)
            lastSubscribedSnapshotRevision = snapshot.revision
            send(data)
        } catch {
            fleetBridgeLog.error("could not encode bridge snapshot: \(error.localizedDescription)")
            close()
        }
    }
""",
    "subscription send",
)
text = replace_once(
    text,
    """            case .snapshot(let request):
                stage = .busy
                send(
                    .snapshot(FleetBridgeSnapshotRecord(
                        requestID: request.id,
                        snapshot: try server.snapshot()
                    )),
                    closeAfter: true
                )
""",
    """            case .snapshot(let request):
                stage = .busy
                let snapshot = try server.snapshot()
                send(
                    try server.encodedSnapshotRecord(requestID: request.id, snapshot: snapshot),
                    closeAfter: true
                )
""",
    "one-shot snapshot send",
)
text = replace_once(
    text,
    """    private func send(
        _ record: FleetBridgeServerRecord,
        closeAfter: Bool = false
    ) {
        guard !isClosed else { return }
        let data: Data
        do {
            data = try FleetBridgeWire.encodeServer(record)
        } catch {
            fleetBridgeLog.error("could not encode bridge response: \(error.localizedDescription)")
            close()
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if error != nil || closeAfter {
                    self.close()
                }
            }
        })
    }
""",
    """    private func send(
        _ record: FleetBridgeServerRecord,
        closeAfter: Bool = false
    ) {
        let data: Data
        do {
            data = try FleetBridgeWire.encodeServer(record)
        } catch {
            fleetBridgeLog.error("could not encode bridge response: \(error.localizedDescription)")
            close()
            return
        }
        send(data, closeAfter: closeAfter)
    }

    private func send(_ data: Data, closeAfter: Bool = false) {
        guard !isClosed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if error != nil || closeAfter { self.close() }
            }
        })
    }
""",
    "encoded send overload",
)
write(path, text)

# Mobile bridge snapshot deduplication.
path = "Sources/HerdrMobile/MobileBridge.swift"
text = read(path)
text = replace_once(text, "      snapshot = next\n      state = .connected(version: \"Bridge \(FleetBridgeProtocol.version)\")\n      onChange?()\n", "      applyConnectedSnapshot(next)\n", "manual bridge refresh")
text = replace_once(text, "          snapshot = next\n          backoff = 1\n          state = .connected(version: \"Bridge \(FleetBridgeProtocol.version)\")\n          onChange?()\n", "          backoff = 1\n          applyConnectedSnapshot(next)\n", "stream bridge refresh")
text = replace_once(
    text,
    "  private func makeClient() throws -> FleetBridgeClient {",
    """  private func applyConnectedSnapshot(_ next: FleetSnapshot) {
    let nextState = MobileConnectionState.connected(
      version: "Bridge \(FleetBridgeProtocol.version)"
    )
    guard snapshot != next || state != nextState else { return }
    snapshot = next
    state = nextState
    onChange?()
  }

  private func makeClient() throws -> FleetBridgeClient {""",
    "bridge apply helper",
)
write(path, text)

# Direct mobile snapshot single-flight coordination.
path = "Sources/HerdrMobile/MobileSessions.swift"
text = read(path)
text = replace_once(text, "@MainActor\nfinal class MobileDeviceSession {\n  let device: MobileDevice\n", "@MainActor\nfinal class MobileDeviceSession {\n  private struct RefreshWorker {\n    let id: UUID\n    let task: Task<Void, Never>\n  }\n\n  let device: MobileDevice\n", "mobile worker type")
text = replace_once(text, "  private var refreshPending = false\n  private var generation: UInt64 = 0\n", "  private var refreshPending = false\n  private var refreshWorker: RefreshWorker?\n  private var refreshRequested = false\n  private var generation: UInt64 = 0\n", "mobile worker properties")
text = replace_once(text, "    eventTask?.cancel()\n    eventTask = nil\n    if let stale = transport {\n", "    eventTask?.cancel()\n    eventTask = nil\n    refreshWorker?.task.cancel()\n    refreshWorker = nil\n    refreshRequested = false\n    if let stale = transport {\n", "connect cancellation")
text = replace_once(text, "      await refresh(generation: expectedGeneration)\n", "      await requestRefresh(generation: expectedGeneration)\n", "initial refresh")
text = replace_once(text, "    eventTask?.cancel()\n    eventTask = nil\n    let stale = transport\n", "    eventTask?.cancel()\n    eventTask = nil\n    refreshWorker?.task.cancel()\n    refreshWorker = nil\n    refreshRequested = false\n    refreshPending = false\n    let stale = transport\n", "disconnect cancellation")
match = re.search(r"  func refresh\(\) async \{\n    await refresh\(generation: nil\)\n  \}\n\n  private func refresh\(generation expectedGeneration: UInt64\?\) async \{\n(?P<body>.*?)\n  \}\n\n  private func startEventPump", text, re.S)
if not match:
    raise RuntimeError("mobile refresh block not found")
body = match.group("body")
body = body.replace("    guard let transport else { return }\n", "    guard generation == expectedGeneration, let transport else { return }\n", 1)
body = body.replace("      if let expectedGeneration, generation != expectedGeneration { return }\n", "      guard generation == expectedGeneration, !Task.isCancelled else { return }\n", 1)
body = body.replace("      snapshot = next\n      onChange?()\n", "      guard snapshot != next else { return }\n      snapshot = next\n      onChange?()\n", 1)
replacement = """  func refresh() async {
    await requestRefresh(generation: generation)
  }

  private func requestRefresh(generation expectedGeneration: UInt64) async {
    guard generation == expectedGeneration else { return }
    refreshRequested = true
    if let refreshWorker {
      await refreshWorker.task.value
      return
    }
    let workerID = UUID()
    let task = Task { [weak self] in
      await self?.drainRefreshRequests(generation: expectedGeneration, workerID: workerID)
    }
    refreshWorker = RefreshWorker(id: workerID, task: task)
    await task.value
  }

  private func drainRefreshRequests(generation expectedGeneration: UInt64, workerID: UUID) async {
    defer {
      if refreshWorker?.id == workerID { refreshWorker = nil }
    }
    while !Task.isCancelled, generation == expectedGeneration, refreshRequested {
      refreshRequested = false
      await performRefresh(generation: expectedGeneration)
    }
  }

  private func performRefresh(generation expectedGeneration: UInt64) async {
""" + body + """
  }

  private func startEventPump"""
text = text[:match.start()] + replacement + text[match.end():]
text = replace_once(text, "    await refresh(generation: expectedGeneration)\n", "    await requestRefresh(generation: expectedGeneration)\n", "scheduled refresh")
write(path, text)

# Mobile fleet index, built once per nested-state revision.
path = "Sources/HerdrMobile/MobileAppModel.swift"
text = read(path)
text = replace_once(text, "import HerdrKit\nimport SwiftUI\n", "import HerdrKit\nimport Observation\nimport SwiftUI\n", "Observation import")
text = replace_once(
    text,
    """  /// Bumped by nested, non-Observable session state.
  private(set) var revision = 0

  private let directStore = MobileDeviceStore()
""",
    """  /// Bumped by nested, non-Observable session state.
  private(set) var revision = 0

  private struct FleetIndex {
    let revision: Int
    let devices: [MobileDeviceEntry]
    let devicesByID: [UUID: MobileDeviceEntry]
    let snapshotsByDeviceID: [UUID: SessionSnapshot]
    let agents: [MobileAgentEntry]
    let agentsByRef: [FleetPaneRef: MobileAgentEntry]
    let terminals: [MobileTerminalEntry]
    let terminalsByRef: [FleetPaneRef: MobileTerminalEntry]
    let workspaceRanks: [UUID: [String: Int]]
    let tabRanks: [UUID: [String: Int]]
    let workspaceNames: [UUID: [String: String]]
    let tabLabels: [UUID: [String: String]]
  }

  private let directStore = MobileDeviceStore()
""",
    "fleet index type",
)
text = replace_once(text, "  private var bridgeSession: MobileBridgeSession?\n", "  private var bridgeSession: MobileBridgeSession?\n  @ObservationIgnored private var fleetIndexCache: FleetIndex?\n", "fleet index cache")
text = regex_once(text, r"  var deviceEntries: \[MobileDeviceEntry\] \{.*?\n  \}\n\n(?=  var selectedDevice: MobileDeviceEntry\? \{)", "  var deviceEntries: [MobileDeviceEntry] {\n    fleetIndex.devices\n  }\n\n", "device entries")
text = replace_once(text, "    return deviceEntries.first { $0.id == selectedDeviceID }\n", "    return fleetIndex.devicesByID[selectedDeviceID]\n", "selected device")
text = regex_once(
    text,
    r"  var spaces: \[MobileSpaceEntry\] \{.*?\n  \}\n\n  var agents: \[MobileAgentEntry\] \{.*?\n  \}\n\n  var terminalPanes: \[MobileTerminalEntry\] \{.*?\n  \}\n",
    """  var spaces: [MobileSpaceEntry] {
    _ = revision
    return scopedDevices.flatMap { device in
      (device.snapshot?.workspaces ?? []).map {
        MobileSpaceEntry(
          ref: FleetSpaceRef(deviceID: device.id, workspaceID: $0.workspaceID),
          workspace: $0,
          device: device
        )
      }
    }
  }

  var agents: [MobileAgentEntry] {
    _ = revision
    return fleetIndex.agents.filter { entry in
      if let selectedDeviceID, entry.ref.deviceID != selectedDeviceID { return false }
      if let selectedSpaceRef {
        return entry.ref.deviceID == selectedSpaceRef.deviceID
          && entry.agent.workspaceID == selectedSpaceRef.workspaceID
      }
      return true
    }
  }

  var terminalPanes: [MobileTerminalEntry] {
    _ = revision
    return fleetIndex.terminals.filter { entry in
      if let selectedDeviceID, entry.ref.deviceID != selectedDeviceID { return false }
      if let selectedSpaceRef {
        return entry.ref.deviceID == selectedSpaceRef.deviceID
          && entry.pane.workspaceID == selectedSpaceRef.workspaceID
      }
      return true
    }
  }
""",
    "derived lists",
)
text = replace_once(text, "    return agentsAcrossFleet.first { $0.ref == selectedPaneRef }\n", "    return fleetIndex.agentsByRef[selectedPaneRef]\n", "selected agent")
text = replace_once(text, "    return terminalsAcrossFleet.first { $0.ref == selectedPaneRef }\n", "    return fleetIndex.terminalsByRef[selectedPaneRef]\n", "selected terminal")
text = regex_once(text, r"  func tabLabel\(for entry: MobileAgentEntry\) -> String\? \{.*?\n  \}\n", "  func tabLabel(for entry: MobileAgentEntry) -> String? {\n    fleetIndex.tabLabels[entry.ref.deviceID]?[entry.agent.tabID]\n  }\n", "tab label")
text = regex_once(text, r"  func spaceName\(deviceID: UUID, workspaceID: String\) -> String \{.*?\n  \}\n", "  func spaceName(deviceID: UUID, workspaceID: String) -> String {\n    fleetIndex.workspaceNames[deviceID]?[workspaceID] ?? workspaceID\n  }\n", "space name")
text = regex_once(text, r"  func terminalLabel\(for entry: MobileTerminalEntry\) -> String \{.*?\n  \}\n", """  func terminalLabel(for entry: MobileTerminalEntry) -> String {
    if let tabID = entry.pane.tabID,
      let label = fleetIndex.tabLabels[entry.ref.deviceID]?[tabID]
    {
      return label
    }
    if let title = entry.pane.terminalTitle, !title.isEmpty { return title }
    return String(localized: "Terminal")
  }
""", "terminal label")
text = replace_once(text, "    selectedDeviceID == nil && deviceEntries.count > 1\n", "    selectedDeviceID == nil && fleetIndex.devices.count > 1\n", "badge count")
text = regex_once(text, r"  private var scopedDevices: \[MobileDeviceEntry\] \{.*?\n  \}\n", """  private var scopedDevices: [MobileDeviceEntry] {
    if let selectedDeviceID, let selected = fleetIndex.devicesByID[selectedDeviceID] {
      return [selected]
    }
    return fleetIndex.devices
  }
""", "scoped devices")
text = regex_once(text, r"  private var agentsAcrossFleet: \[MobileAgentEntry\] \{.*?\n  \}\n", "  private var agentsAcrossFleet: [MobileAgentEntry] { fleetIndex.agents }\n", "all agents")
text = regex_once(text, r"  private var terminalsAcrossFleet: \[MobileTerminalEntry\] \{.*?\n  \}\n", "  private var terminalsAcrossFleet: [MobileTerminalEntry] { fleetIndex.terminals }\n", "all terminals")
text = regex_once(text, r"  private func snapshot\(for deviceID: UUID\) -> SessionSnapshot\? \{.*?\n  \}\n", "  private func snapshot(for deviceID: UUID) -> SessionSnapshot? {\n    fleetIndex.snapshotsByDeviceID[deviceID]\n  }\n", "snapshot lookup")
text = regex_once(text, r"  private func workspaceRank\(deviceID: UUID, workspaceID: String\) -> Int \{.*?\n  \}\n", "  private func workspaceRank(deviceID: UUID, workspaceID: String) -> Int {\n    fleetIndex.workspaceRanks[deviceID]?[workspaceID] ?? Int.max\n  }\n", "workspace rank")
text = regex_once(text, r"  private func tabRank\(deviceID: UUID, tabID: String\) -> Int \{.*?\n  \}\n", "  private func tabRank(deviceID: UUID, tabID: String) -> Int {\n    fleetIndex.tabRanks[deviceID]?[tabID] ?? Int.max\n  }\n", "tab rank")
text = text.replace("      self?.revision += 1\n      self?.reconcileSelection()\n", "      self?.invalidateFleetIndex()\n      self?.reconcileSelection()\n")
text = text.replace("    revision += 1\n", "    invalidateFleetIndex()\n")
text = replace_once(text, "    configureBridgeSession()\n    selectedDeviceID = nil\n", "    configureBridgeSession()\n    invalidateFleetIndex()\n    selectedDeviceID = nil\n", "add bridge invalidation")
text = replace_once(text, "    directStore.save(directDevices)\n    selectDevice(device.id)\n", "    directStore.save(directDevices)\n    invalidateFleetIndex()\n    selectDevice(device.id)\n", "add direct invalidation")
anchor = "  private func directSession(for deviceID: UUID) -> MobileDeviceSession? {"
index_impl = """  private var fleetIndex: FleetIndex {
    _ = revision
    if let fleetIndexCache, fleetIndexCache.revision == revision { return fleetIndexCache }
    let index = makeFleetIndex()
    fleetIndexCache = index
    return index
  }

  private func makeFleetIndex() -> FleetIndex {
    var devices: [MobileDeviceEntry] = []
    if let bridgeSession, let fleet = bridgeSession.snapshot {
      let live = bridgeSession.state.isConnected
      for device in fleet.devices {
        devices.append(MobileDeviceEntry(
          id: device.id,
          source: .bridge,
          name: device.device.name,
          subtitle: device.device.subtitle,
          state: live ? MobileConnectionState(device.connection) : bridgeSession.state,
          snapshot: device.snapshot,
          availableAgentKinds: device.availableAgentKinds
        ))
      }
    }
    for device in directDevices {
      let session = directSession(for: device.id)
      devices.append(MobileDeviceEntry(
        id: device.id,
        source: .direct,
        name: device.name,
        subtitle: device.subtitle,
        state: session?.state ?? .idle,
        snapshot: session?.snapshot,
        availableAgentKinds: []
      ))
    }

    var devicesByID: [UUID: MobileDeviceEntry] = [:]
    var snapshots: [UUID: SessionSnapshot] = [:]
    var agents: [MobileAgentEntry] = []
    var agentsByRef: [FleetPaneRef: MobileAgentEntry] = [:]
    var terminals: [MobileTerminalEntry] = []
    var terminalsByRef: [FleetPaneRef: MobileTerminalEntry] = [:]
    var workspaceRanks: [UUID: [String: Int]] = [:]
    var tabRanks: [UUID: [String: Int]] = [:]
    var workspaceNames: [UUID: [String: String]] = [:]
    var tabLabels: [UUID: [String: String]] = [:]
    for device in devices {
      devicesByID[device.id] = device
      guard let snapshot = device.snapshot else { continue }
      snapshots[device.id] = snapshot
      workspaceRanks[device.id] = Dictionary(uniqueKeysWithValues: snapshot.workspaces.enumerated().map { ($1.workspaceID, $0) })
      workspaceNames[device.id] = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0.label) })
      tabRanks[device.id] = Dictionary(uniqueKeysWithValues: (snapshot.tabs ?? []).enumerated().map { ($1.tabID, $0) })
      tabLabels[device.id] = Dictionary(uniqueKeysWithValues: (snapshot.tabs ?? []).compactMap { tab in tab.customLabel.map { (tab.tabID, $0) } })
      for agent in snapshot.agents {
        let entry = MobileAgentEntry(ref: FleetPaneRef(deviceID: device.id, paneID: agent.paneID), agent: agent, device: device)
        agents.append(entry)
        agentsByRef[entry.ref] = entry
      }
      for pane in snapshot.ordinaryTerminalPanes {
        let entry = MobileTerminalEntry(ref: FleetPaneRef(deviceID: device.id, paneID: pane.paneID), pane: pane, device: device)
        terminals.append(entry)
        terminalsByRef[entry.ref] = entry
      }
    }
    let deviceRanks = Dictionary(uniqueKeysWithValues: devices.enumerated().map { ($1.id, $0) })
    agents.sort { lhs, rhs in
      if lhs.agent.status.sortBucket != rhs.agent.status.sortBucket {
        return lhs.agent.status.sortBucket < rhs.agent.status.sortBucket
      }
      let leftDevice = deviceRanks[lhs.ref.deviceID] ?? Int.max
      let rightDevice = deviceRanks[rhs.ref.deviceID] ?? Int.max
      if leftDevice != rightDevice { return leftDevice < rightDevice }
      let leftWorkspace = workspaceRanks[lhs.ref.deviceID]?[lhs.agent.workspaceID] ?? Int.max
      let rightWorkspace = workspaceRanks[rhs.ref.deviceID]?[rhs.agent.workspaceID] ?? Int.max
      if leftWorkspace != rightWorkspace { return leftWorkspace < rightWorkspace }
      return (tabRanks[lhs.ref.deviceID]?[lhs.agent.tabID] ?? Int.max)
        < (tabRanks[rhs.ref.deviceID]?[rhs.agent.tabID] ?? Int.max)
    }
    return FleetIndex(
      revision: revision,
      devices: devices,
      devicesByID: devicesByID,
      snapshotsByDeviceID: snapshots,
      agents: agents,
      agentsByRef: agentsByRef,
      terminals: terminals,
      terminalsByRef: terminalsByRef,
      workspaceRanks: workspaceRanks,
      tabRanks: tabRanks,
      workspaceNames: workspaceNames,
      tabLabels: tabLabels
    )
  }

  private func invalidateFleetIndex() {
    revision &+= 1
    fleetIndexCache = nil
  }

"""
text = replace_once(text, anchor, index_impl + anchor, "fleet index builder")
write(path, text)

# Terminal UI batching.
path = "Sources/HerdrMobile/MobileTerminalView.swift"
text = read(path)
text = replace_once(text, "    private var lastSize = TerminalSize(columns: 80, rows: 24)\n    weak var terminalView: TerminalView?\n", "    private var lastSize = TerminalSize(columns: 80, rows: 24)\n    private var pendingTerminalBytes = Data()\n    private var feedTask: Task<Void, Never>?\n    private static let maximumFeedBatchBytes = 64 * 1024\n    private static let feedBatchDelay: Duration = .milliseconds(8)\n    weak var terminalView: TerminalView?\n", "terminal batching properties")
text = replace_once(text, "                    self?.feed(frame.bytes)\n", "                    self?.enqueueTerminalBytes(frame.bytes)\n", "terminal enqueue")
text = replace_once(
    text,
    """    private func feed(_ data: Data) {
        terminalView?.feed(byteArray: ArraySlice([UInt8](data)))
    }
""",
    """    private func enqueueTerminalBytes(_ data: Data) {
        guard terminalView != nil else { return }
        pendingTerminalBytes.append(data)
        if pendingTerminalBytes.count >= Self.maximumFeedBatchBytes {
            flushTerminalBytes()
            return
        }
        guard feedTask == nil else { return }
        let generation = lifecycleGeneration
        feedTask = Task { [weak self] in
            try? await Task.sleep(for: Self.feedBatchDelay)
            guard let self, !Task.isCancelled, self.lifecycleGeneration == generation else { return }
            self.feedTask = nil
            self.flushTerminalBytes()
        }
    }

    private func flushTerminalBytes() {
        feedTask?.cancel()
        feedTask = nil
        guard !pendingTerminalBytes.isEmpty else { return }
        let bytes = [UInt8](pendingTerminalBytes)
        pendingTerminalBytes.removeAll(keepingCapacity: true)
        terminalView?.feed(byteArray: bytes[...])
    }
""",
    "terminal feed",
)
text = replace_once(text, "            await terminalSession.close()\n            guard\n", "            self?.flushTerminalBytes()\n            await terminalSession.close()\n            guard\n", "terminal tail flush")
text = replace_once(text, "        resizeTask?.cancel()\n        resizeTask = nil\n        startTask?.cancel()\n", "        resizeTask?.cancel()\n        resizeTask = nil\n        feedTask?.cancel()\n        feedTask = nil\n        pendingTerminalBytes.removeAll(keepingCapacity: true)\n        startTask?.cancel()\n", "terminal stop")
write(path, text)

print("Optimization patch applied.")
