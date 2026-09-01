import AppKit
import CoreServices
import ServiceManagement

/// Keeps the Mac-owned fleet bridge reachable when HerdrM has no open windows.
///
/// The bridge deliberately remains in the main app process: that process already
/// owns the live `AppModel`, SSH tunnels, Keychain access, and terminal children.
/// Registering the main app as a login item avoids duplicating those credentials
/// or creating a second competing device-session owner.
enum FleetBridgeBackgroundLaunch {
    enum Status: Equatable {
        case disabled
        case enabled
        case requiresApproval
        case unavailable
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    static var isRequested: Bool {
        switch status {
        case .enabled, .requiresApproval:
            return true
        case .disabled, .unavailable:
            return false
        }
    }

    /// Login-item launches carry this marker in the open-application event's
    /// property-data parameter. User launches do not, so the normal app window
    /// remains visible.
    static var launchedAsLoginItem: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            switch service.status {
            case .enabled, .requiresApproval:
                return
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
        } else {
            switch service.status {
            case .notRegistered, .notFound:
                return
            case .enabled, .requiresApproval:
                try service.unregister()
            @unknown default:
                try service.unregister()
            }
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Menu-bar presentation used only while the login-item/background bridge has
/// no visible application window. Explicit Quit still tears down every session.
@MainActor
final class FleetBridgeBackgroundController: NSObject {
    static let shared = FleetBridgeBackgroundController()

    private var statusItem: NSStatusItem?
    private(set) var isBackgroundOnly = false

    func enterIfConfigured() {
        guard FleetBridgeBackgroundLaunch.isRequested,
              FleetBridgeHostConfiguration.load().enabled
        else { return }

        isBackgroundOnly = true
        for window in NSApp.windows where window.isVisible {
            window.orderOut(nil)
        }
        _ = NSApp.setActivationPolicy(.accessory)
        installStatusItemIfNeeded()
    }

    func leaveBackgroundMode() {
        isBackgroundOnly = false
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        _ = NSApp.setActivationPolicy(.regular)
    }

    /// Returns true when an existing hidden SwiftUI window was restored. When
    /// false, AppKit's normal reopen handling creates a new WindowGroup window.
    func prepareForReopen(_ application: NSApplication) -> Bool {
        leaveBackgroundMode()
        guard let window = application.windows.first(where: {
            !$0.isVisible && $0.styleMask.contains(.fullSizeContentView)
        }) else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        return true
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "iphone",
            accessibilityDescription: String(localized: "HerdrM Mobile Bridge")
        )
        item.button?.toolTip = String(localized: "HerdrM mobile bridge is running")

        let menu = NSMenu()
        let open = NSMenuItem(
            title: String(localized: "Open HerdrM"),
            action: #selector(openApplication(_:)),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: String(localized: "Quit HerdrM"),
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func openApplication(_ sender: Any?) {
        leaveBackgroundMode()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration,
            completionHandler: nil
        )
    }

    @objc private func quitApplication(_ sender: Any?) {
        NSApp.terminate(sender)
    }
}
