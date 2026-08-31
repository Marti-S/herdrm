import AppKit

@MainActor
extension AppDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        FleetBridgeRuntime.shared.start(model: model)
    }
}
