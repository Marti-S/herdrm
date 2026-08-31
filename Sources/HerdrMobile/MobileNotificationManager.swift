import Foundation
import HerdrKit
import UserNotifications

/// Posts local banners for live Agent transitions while the app is running and
/// reveals the originating fleet pane when the notification is opened.
@MainActor
final class MobileNotificationManager: NSObject, UNUserNotificationCenterDelegate {
  static let shared = MobileNotificationManager()

  private weak var model: MobileAppModel?
  private var pendingReveal: FleetPaneRef?
  private var authorized = false
  private var didSetup = false

  func setup(model: MobileAppModel) {
    self.model = model
    if let pendingReveal {
      model.reveal(pendingReveal)
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

  func post(
    agent: AgentInfo,
    title: String,
    status: AgentStatus,
    ref: FleetPaneRef,
    deviceName: String,
    spaceName: String
  ) {
    guard authorized,
      UserDefaults.standard.object(forKey: "notifications.enabled") as? Bool ?? true
    else { return }

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
        model.reveal(ref)
      } else {
        self.pendingReveal = ref
      }
    }
    completionHandler()
  }
}
