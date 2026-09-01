import AppKit

extension AppDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        FleetBridgeServer.shared.start(model: model)
        installMobilePairingMenuItem()

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

    @objc private func showMobilePairing(_ sender: Any?) {
        FleetBridgePairingWindowController.shared.show(model: model)
    }

    private func installMobilePairingMenuItem() {
        guard let applicationMenu = NSApp.mainMenu?.items.first?.submenu,
              !applicationMenu.items.contains(where: { $0.action == #selector(showMobilePairing(_:)) })
        else { return }

        let item = NSMenuItem(
            title: String(localized: "Mobile Pairing…"),
            action: #selector(showMobilePairing(_:)),
            keyEquivalent: ""
        )
        item.target = self
        let insertionIndex = min(2, applicationMenu.items.count)
        applicationMenu.insertItem(item, at: insertionIndex)
    }
}
