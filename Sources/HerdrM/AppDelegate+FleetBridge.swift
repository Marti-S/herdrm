import AppKit

extension AppDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        FleetBridgeServer.shared.start(model: model)
    }

    func applicationWillTerminate(_ notification: Notification) {
        FleetBridgeServer.shared.stop()
    }
}
