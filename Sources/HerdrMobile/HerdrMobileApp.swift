import SwiftUI

@main
struct HerdrMobileApp: App {
    @State private var model = MobileAppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UserDefaults.standard.set(
            DeviceKey.authorizedKeysLine(DeviceKey.ensure()),
            forKey: "deviceKey.publicLine"
        )
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            // Network.framework and SSH connections may be suspended in the
            // background. Reconnect and accept a complete fleet snapshot when
            // the scene becomes active again.
            if phase == .active {
                model.activate()
            }
        }
    }
}
