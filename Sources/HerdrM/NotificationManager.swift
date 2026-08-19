import AppKit
import HerdrKit
import UserNotifications

/// Posts macOS notifications when an agent finishes or gets blocked, and jumps
/// to the agent when a notification is clicked.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    weak var model: AppModel?
    private var authorized = false

    func setup(model: AppModel) {
        self.model = model
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    /// Chime played in-app (like herdr's bell) so it works regardless of how the
    /// system chooses to deliver the banner.
    func playSound(for status: AgentStatus) {
        guard UserDefaults.standard.object(forKey: "notifications.sound") as? Bool ?? true else { return }
        let name: String
        switch status {
        case .done: name = "Glass"
        case .blocked: name = "Funk"
        default: return
        }
        NSSound(named: name)?.play()
    }

    func post(agent: AgentInfo, status: AgentStatus, deviceID: UUID, deviceName: String, spaceName: String) {
        playSound(for: status)
        guard authorized, UserDefaults.standard.object(forKey: "notifications.enabled") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = agent.title
        switch status {
        case .blocked:
            content.body = "\(agent.agent) needs your input · \(spaceName) · \(deviceName)"
        case .done:
            content.body = "\(agent.agent) finished · \(spaceName) · \(deviceName)"
        default:
            return
        }
        content.userInfo = ["paneID": agent.paneID, "deviceID": deviceID.uuidString]
        let request = UNNotificationRequest(
            identifier: "agent-\(deviceID.uuidString)-\(agent.paneID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Show banners even while the app is frontmost (herdr already suppresses
    // "done" for the pane you are actively watching).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let paneID = info["paneID"] as? String
        let deviceID = (info["deviceID"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            guard let model = self?.model, let paneID, let deviceID else { return }
            model.reveal(PaneRef(deviceID: deviceID, paneID: paneID))
        }
        completionHandler()
    }
}
