import Foundation
import HerdrKit
import SwiftUI

@MainActor
@Observable
final class MobileAppModel {
  var bridge: MobileBridge?
  var directDevices: [MobileDevice] = []
  /// nil means All Devices.
  var selectedDeviceID: UUID?
  var selectedSpaceRef: FleetSpaceRef?
  var selectedPaneRef: FleetPaneRef?
  var showAddConnection = false
  var actionError: String?

  /// Bumped by nested, non-Observable session state.
  private(set) var revision = 0

  private let directStore = MobileDeviceStore()
  private let bridgeStore = MobileBridgeStore()
  private var directSessions: [UUID: MobileDeviceSession] = [:]
  private var bridgeSession: MobileBridgeSession?

  init() {
    bridge = bridgeStore.load()
    directDevices = directStore.load()
    configureBridgeSession()
    selectedDeviceID = bridge == nil ? directDevices.first?.id : nil
  }

  var hasConfiguredSources: Bool {
    bridge != nil || !directDevices.isEmpty
  }

  var deviceEntries: [MobileDeviceEntry] {
    _ = revision
    var result: [MobileDeviceEntry] = []

    if let bridgeSession,
      let fleet = bridgeSession.snapshot
    {
      let bridgeIsLive = bridgeSession.state.isConnected
      for device in fleet.devices {
        result.append(
          MobileDeviceEntry(
            id: device.id,
            source: .bridge,
            name: device.device.name,
            subtitle: device.device.subtitle,
            state: bridgeIsLive ? MobileConnectionState(device.connection) : bridgeSession.state,
            snapshot: device.snapshot,
            availableAgentKinds: device.availableAgentKinds
          ))
      }
    }

    for device in directDevices {
      let session = directSession(for: device.id)
      result.append(
        MobileDeviceEntry(
          id: device.id,
          source: .direct,
          name: device.name,
          subtitle: device.subtitle,
          state: session?.state ?? .idle,
          snapshot: session?.snapshot,
          availableAgentKinds: []
        ))
    }
    return result
  }

  var selectedDevice: MobileDeviceEntry? {
    guard let selectedDeviceID else { return nil }
    return deviceEntries.first { $0.id == selectedDeviceID }
  }

  var selectedConnectionState: MobileConnectionState {
    _ = revision
    if let selectedDevice { return selectedDevice.state }

    if let bridgeSession, !bridgeSession.state.isConnected {
      return bridgeSession.state
    }
    let states = deviceEntries.map(\.state)
    if let failed = states.first(where: {
      if case .failed = $0 { return true }
      return false
    }) {
      return failed
    }
    if states.contains(.connecting) { return .connecting }
    if !states.isEmpty, states.allSatisfy(\.isConnected) {
      return .connected(version: "")
    }
    return states.isEmpty ? .idle : .connecting
  }

  var bridgeConnectionState: MobileConnectionState {
    _ = revision
    return bridgeSession?.state ?? .idle
  }

  func activate() {
    if let bridgeSession {
      Task { await bridgeSession.reconnect() }
    }
    for device in directDevices {
      guard let session = directSession(for: device.id) else { continue }
      Task { await session.reconnect() }
    }
  }

  func deactivate() {
    let bridgeSession = bridgeSession
    let sessions = Array(directSessions.values)
    Task {
      await bridgeSession?.disconnect()
      for session in sessions {
        await session.disconnect()
      }
    }
  }

  func refreshAll() async {
    await bridgeSession?.refresh()
    for session in directSessions.values {
      await session.refresh()
    }
  }

  func selectDevice(_ id: UUID?) {
    guard id != selectedDeviceID else { return }
    selectedDeviceID = id
    selectedSpaceRef = nil
    selectedPaneRef = nil
    if let id,
      let direct = directDevices.first(where: { $0.id == id }),
      let session = directSession(for: direct.id)
    {
      Task { await session.connect() }
    }
  }

  func selectSpace(_ ref: FleetSpaceRef?) {
    selectedSpaceRef = ref
    guard let ref else { return }
    if let selectedPaneRef,
      selectedPaneRef.deviceID == ref.deviceID,
      let snapshot = snapshot(for: ref.deviceID)
    {
      let workspaceID =
        snapshot.agents
        .first { $0.paneID == selectedPaneRef.paneID }?.workspaceID
        ?? snapshot.ordinaryTerminalPanes
        .first { $0.paneID == selectedPaneRef.paneID }?.workspaceID
      if workspaceID == ref.workspaceID { return }
    }

    let candidates = agents
    selectedPaneRef =
      candidates.first(where: { $0.agent.status == .blocked })?.ref
      ?? candidates.first(where: { $0.agent.status == .done })?.ref
      ?? candidates.first(where: { $0.agent.status == .working })?.ref
      ?? candidates.first?.ref
      ?? terminalPanes.first?.ref
  }

  func transport(for deviceID: UUID) -> (any MobileTransport)? {
    _ = revision
    if bridgeSession?.snapshot?.device(deviceID) != nil {
      return bridgeSession?.transport(for: deviceID)
    }
    return directSession(for: deviceID)?.transport
  }

  // MARK: - Source management

  func addBridge(
    name: String,
    host: String,
    port: UInt16,
    token: String,
    expectedServerID: UUID?
  ) throws {
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedHost.isEmpty, port > 0 else {
      throw FleetBridgeClientError.invalidEndpoint
    }
    guard let expectedServerID else {
      throw MobileBridgePairingError.invalid(
        "The Mac identity is missing. Paste its pairing JSON or enter its server ID.")
    }
    guard !trimmedToken.isEmpty else {
      throw MobileBridgePairingError.invalid("The pairing token is missing.")
    }
    let id = expectedServerID
    let next = MobileBridge(
      id: id,
      expectedServerID: expectedServerID,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? trimmedHost : name.trimmingCharacters(in: .whitespacesAndNewlines),
      host: trimmedHost,
      port: port
    )
    try MobileBridgeSecretStore.setToken(trimmedToken, for: id)

    if let previous = bridge, previous.id != id {
      try? MobileBridgeSecretStore.removeToken(for: previous.id)
    }
    let oldSession = bridgeSession
    bridge = next
    bridgeStore.save(next)
    configureBridgeSession()
    selectedDeviceID = nil
    selectedSpaceRef = nil
    selectedPaneRef = nil
    Task { await oldSession?.disconnect() }
    bridgeSession?.connect()
  }

  func removeBridge() {
    guard let bridge else { return }
    let oldSession = bridgeSession
    try? MobileBridgeSecretStore.removeToken(for: bridge.id)
    self.bridge = nil
    bridgeStore.save(nil)
    bridgeSession = nil
    selectedDeviceID = directDevices.first?.id
    selectedSpaceRef = nil
    selectedPaneRef = nil
    revision += 1
    Task { await oldSession?.disconnect() }
  }

  func addDirectDevice(
    name: String,
    host: String,
    port: UInt16,
    username: String,
    authMethod: MobileDevice.AuthMethod,
    password: String
  ) {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let device = MobileDevice(
      name: trimmedName.isEmpty ? host : trimmedName,
      host: host.trimmingCharacters(in: .whitespacesAndNewlines),
      port: port,
      username: username.trimmingCharacters(in: .whitespacesAndNewlines),
      authMethod: authMethod
    )
    if authMethod == .password {
      MobileSecretStore.setPassword(password, for: device.id)
    }
    directDevices.append(device)
    directStore.save(directDevices)
    selectDevice(device.id)
  }

  var deviceKeyAuthorizedLine: String {
    DeviceKey.authorizedKeysLine(DeviceKey.ensure())
  }

  func removeDirectDevice(_ id: UUID) {
    guard let device = directDevices.first(where: { $0.id == id }) else { return }
    if let session = directSessions.removeValue(forKey: id) {
      Task { await session.disconnect() }
    }
    MobileSecretStore.removePassword(for: device.id)
    KnownHostsStore.unpin(host: device.host, port: device.port)
    directDevices.removeAll { $0.id == id }
    directStore.save(directDevices)
    if selectedDeviceID == id {
      selectedDeviceID = bridge == nil ? directDevices.first?.id : nil
      selectedSpaceRef = nil
      selectedPaneRef = nil
    }
    revision += 1
  }

  // MARK: - Derived fleet lists

  var spaces: [MobileSpaceEntry] {
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
    var entries = scopedDevices.flatMap { device in
      (device.snapshot?.agents ?? []).map {
        MobileAgentEntry(
          ref: FleetPaneRef(deviceID: device.id, paneID: $0.paneID),
          agent: $0,
          device: device
        )
      }
    }
    if let selectedSpaceRef {
      entries = entries.filter {
        $0.ref.deviceID == selectedSpaceRef.deviceID
          && $0.agent.workspaceID == selectedSpaceRef.workspaceID
      }
    }

    let deviceRank = Dictionary(
      uniqueKeysWithValues: scopedDevices.enumerated().map { ($1.id, $0) }
    )
    return entries.sorted { lhs, rhs in
      if lhs.agent.status.sortBucket != rhs.agent.status.sortBucket {
        return lhs.agent.status.sortBucket < rhs.agent.status.sortBucket
      }
      let leftDevice = deviceRank[lhs.ref.deviceID] ?? Int.max
      let rightDevice = deviceRank[rhs.ref.deviceID] ?? Int.max
      if leftDevice != rightDevice { return leftDevice < rightDevice }
      let leftWorkspace = workspaceRank(
        deviceID: lhs.ref.deviceID,
        workspaceID: lhs.agent.workspaceID
      )
      let rightWorkspace = workspaceRank(
        deviceID: rhs.ref.deviceID,
        workspaceID: rhs.agent.workspaceID
      )
      if leftWorkspace != rightWorkspace { return leftWorkspace < rightWorkspace }
      return tabRank(deviceID: lhs.ref.deviceID, tabID: lhs.agent.tabID)
        < tabRank(deviceID: rhs.ref.deviceID, tabID: rhs.agent.tabID)
    }
  }

  var terminalPanes: [MobileTerminalEntry] {
    _ = revision
    var entries = scopedDevices.flatMap { device in
      (device.snapshot?.ordinaryTerminalPanes ?? []).map {
        MobileTerminalEntry(
          ref: FleetPaneRef(deviceID: device.id, paneID: $0.paneID),
          pane: $0,
          device: device
        )
      }
    }
    if let selectedSpaceRef {
      entries = entries.filter {
        $0.ref.deviceID == selectedSpaceRef.deviceID
          && $0.pane.workspaceID == selectedSpaceRef.workspaceID
      }
    }
    return entries
  }

  var selectedAgent: MobileAgentEntry? {
    guard let selectedPaneRef else { return nil }
    return agentsAcrossFleet.first { $0.ref == selectedPaneRef }
  }

  var selectedTerminalPane: MobileTerminalEntry? {
    guard let selectedPaneRef else { return nil }
    return terminalsAcrossFleet.first { $0.ref == selectedPaneRef }
  }

  func tabLabel(for entry: MobileAgentEntry) -> String? {
    snapshot(for: entry.ref.deviceID)?.tabs?
      .first { $0.tabID == entry.agent.tabID }?.customLabel
  }

  func spaceName(deviceID: UUID, workspaceID: String) -> String {
    snapshot(for: deviceID)?.workspaces
      .first { $0.workspaceID == workspaceID }?.label ?? workspaceID
  }

  func terminalLabel(for entry: MobileTerminalEntry) -> String {
    if let tabID = entry.pane.tabID,
      let label = snapshot(for: entry.ref.deviceID)?.tabs?
        .first(where: { $0.tabID == tabID })?.customLabel
    {
      return label
    }
    if let title = entry.pane.terminalTitle, !title.isEmpty { return title }
    return String(localized: "Terminal")
  }

  var showsDeviceBadges: Bool {
    selectedDeviceID == nil && deviceEntries.count > 1
  }

  private var scopedDevices: [MobileDeviceEntry] {
    if let selectedDeviceID {
      return deviceEntries.filter { $0.id == selectedDeviceID }
    }
    return deviceEntries
  }

  private var agentsAcrossFleet: [MobileAgentEntry] {
    deviceEntries.flatMap { device in
      (device.snapshot?.agents ?? []).map {
        MobileAgentEntry(
          ref: FleetPaneRef(deviceID: device.id, paneID: $0.paneID),
          agent: $0,
          device: device
        )
      }
    }
  }

  private var terminalsAcrossFleet: [MobileTerminalEntry] {
    deviceEntries.flatMap { device in
      (device.snapshot?.ordinaryTerminalPanes ?? []).map {
        MobileTerminalEntry(
          ref: FleetPaneRef(deviceID: device.id, paneID: $0.paneID),
          pane: $0,
          device: device
        )
      }
    }
  }

  private func snapshot(for deviceID: UUID) -> SessionSnapshot? {
    if let snapshot = bridgeSession?.snapshot?.device(deviceID)?.snapshot {
      return snapshot
    }
    return directSession(for: deviceID)?.snapshot
  }

  private func directSession(for deviceID: UUID) -> MobileDeviceSession? {
    if let existing = directSessions[deviceID] { return existing }
    guard let device = directDevices.first(where: { $0.id == deviceID }) else { return nil }
    let session = MobileDeviceSession(device: device)
    session.onChange = { [weak self] in
      self?.revision += 1
      self?.reconcileSelection()
    }
    directSessions[deviceID] = session
    return session
  }

  private func configureBridgeSession() {
    guard let bridge else {
      bridgeSession = nil
      return
    }
    let session = MobileBridgeSession(bridge: bridge)
    session.onChange = { [weak self] in
      self?.revision += 1
      self?.reconcileSelection()
    }
    bridgeSession = session
  }

  private func workspaceRank(deviceID: UUID, workspaceID: String) -> Int {
    snapshot(for: deviceID)?.workspaces
      .firstIndex { $0.workspaceID == workspaceID } ?? Int.max
  }

  private func tabRank(deviceID: UUID, tabID: String) -> Int {
    snapshot(for: deviceID)?.tabs?
      .firstIndex { $0.tabID == tabID } ?? Int.max
  }

  private func reconcileSelection() {
    if let selectedSpaceRef {
      guard let snapshot = snapshot(for: selectedSpaceRef.deviceID) else {
        self.selectedSpaceRef = nil
        self.selectedPaneRef = nil
        return
      }
      if !snapshot.workspaces.contains(where: {
        $0.workspaceID == selectedSpaceRef.workspaceID
      }) {
        self.selectedSpaceRef = nil
      }
    }

    if let selectedPaneRef {
      guard let snapshot = snapshot(for: selectedPaneRef.deviceID) else {
        self.selectedPaneRef = nil
        return
      }
      let paneExists =
        snapshot.agents.contains { $0.paneID == selectedPaneRef.paneID }
        || snapshot.ordinaryTerminalPanes.contains { $0.paneID == selectedPaneRef.paneID }
      if !paneExists { self.selectedPaneRef = nil }
    }
  }
}
