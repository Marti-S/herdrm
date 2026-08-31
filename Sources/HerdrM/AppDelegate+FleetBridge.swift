import AppKit

extension AppDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        FleetBridgeServer.shared.start(model: model)
        installMobilePairingMenuItem()
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
