import Foundation
import HerdrKit
import UserNotifications

/// Observes fleet snapshots for Agent lifecycle transitions and posts local
/// notifications. Device and pane IDs in every request make notification taps
/// unambiguous across the Mac-owned fleet.
@MainActor
final class MobileNotificationManager: NSObject, UNUserNotificationCenterDelegate {
  static let shared = MobileNotificationManager()

  private weak var model: MobileAppModel?
  private var pendingReveal: FleetPaneRef?
  private var previousStatuses: [UUID: [String: AgentStatus]] = [:]
  private var authorized = false
  private var didSetup = false

  func setup(model: MobileAppModel) {
    self.model = model
    if let pendingReveal {
      reveal(pendingReveal, in: model)
      self.pendingReveal = nil
    }
    guard !didSetup else { return }
    didSetup = true

    let center = UNUserNotificationCenter.current()
    center.delegate = self
    Task {
      authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
  }

  func process(model: MobileAppModel) {
    let devices = model.deviceEntries
    let liveDeviceIDs = Set(devices.map(\.id))
    previousStatuses = previousStatuses.filter { liveDeviceIDs.contains($0.key) }

    for device in devices {
      guard let snapshot = device.snapshot else { continue }
      let previous = previousStatuses[device.id] ?? [:]
      if !previous.isEmpty {
        postTransitions(
          device: device,
          snapshot: snapshot,
          previous: previous,
          selectedPane: model.selectedPaneRef
        )
      }
      previousStatuses[device.id] = Dictionary(
        uniqueKeysWithValues: snapshot.agents.map { ($0.paneID, $0.status) }
      )
    }
  }

  private func postTransitions(
    device: MobileDeviceEntry,
    snapshot: SessionSnapshot,
    previous: [String: AgentStatus],
    selectedPane: FleetPaneRef?
  ) {
    guard authorized,
      UserDefaults.standard.object(forKey: "notifications.enabled") as? Bool ?? true
    else { return }

    for agent in snapshot.agents {
      guard let old = previous[agent.paneID], old != agent.status else { continue }
      guard agent.status == .blocked || agent.status == .done else { continue }

      let ref = FleetPaneRef(deviceID: device.id, paneID: agent.paneID)
      // Keep the unread marker for a terminal that just finished on screen, but
      // avoid presenting a redundant banner over the terminal being watched.
      if agent.status == .done, selectedPane == ref { continue }

      let tabLabel = snapshot.tabs?
        .first { $0.tabID == agent.tabID }?.customLabel
      let spaceName = snapshot.workspaces
        .first { $0.workspaceID == agent.workspaceID }?.label
        ?? agent.workspaceID
      post(
        agent: agent,
        title: agent.title(tabLabel: tabLabel),
        status: agent.status,
        ref: ref,
        deviceName: device.name,
        spaceName: spaceName
      )
    }
  }

  private func post(
    agent: AgentInfo,
    title: String,
    status: AgentStatus,
    ref: FleetPaneRef,
    deviceName: String,
    spaceName: String
  ) {
    let content = UNMutableNotificationContent()
    content.title = title
    switch status {
    case .blocked:
      content.body = String(
        localized: "\(agent.agent) needs your input · \(spaceName) · \(deviceName)"
      )
    case .done:
      content.body = String(
        localized: "\(agent.agent) finished · \(spaceName) · \(deviceName)"
      )
    default:
      return
    }
    if UserDefaults.standard.object(forKey: "notifications.sound") as? Bool ?? true {
      content.sound = .default
    }
    content.userInfo = [
      "deviceID": ref.deviceID.uuidString,
      "paneID": ref.paneID,
    ]

    let request = UNNotificationRequest(
      identifier: "agent-\(ref.deviceID.uuidString)-\(ref.paneID)",
      content: content,
      trigger: nil
    )
    Task { try? await UNUserNotificationCenter.current().add(request) }
  }

  private func reveal(_ ref: FleetPaneRef, in model: MobileAppModel) {
    if let selectedDeviceID = model.selectedDeviceID,
      selectedDeviceID != ref.deviceID
    {
      model.selectDevice(nil)
    }
    model.selectedSpaceRef = nil
    model.selectedPaneRef = ref
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    let paneID = info["paneID"] as? String
    let deviceID = (info["deviceID"] as? String).flatMap(UUID.init(uuidString:))
    Task { @MainActor [weak self] in
      guard let self, let paneID, let deviceID else { return }
      let ref = FleetPaneRef(deviceID: deviceID, paneID: paneID)
      if let model = self.model {
        self.reveal(ref, in: model)
      } else {
        self.pendingReveal = ref
      }
    }
    completionHandler()
  }
}
