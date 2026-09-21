import AppKit

extension AppDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        FleetBridgeServer.shared.start(model: model)
        // A login-item launch should establish every device session without
        // making the user keep a HerdrM window open. RootView normally starts
        // the model on appearance; this fallback covers launch flows where the
        // initial window never reaches appearance before backgrounding.
        if FleetBridgeBackgroundLaunch.launchedAsLoginItem {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.model.devices.contains(where: { self.model.sessions[$0.id] == nil }) {
                    self.model.start()
                }
                FleetBridgeBackgroundController.shared.enterIfConfigured()
            }
        }
    }

    /// Closing the last window must never tear down the Mac-owned bridge or its
    /// SSH tunnels. With background launch enabled, HerdrM becomes a menu-bar
    /// process until the user opens it again or explicitly quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        DispatchQueue.main.async {
            FleetBridgeBackgroundController.shared.enterIfConfigured()
        }
        return false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if FleetBridgeBackgroundController.shared.prepareForReopen(sender) {
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        FleetBridgeServer.shared.stop()
    }
}
