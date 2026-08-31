import SwiftUI

@main
struct HerdrMobileApp: App {
  @State private var model = MobileAppModel()
  @Environment(\.scenePhase) private var scenePhase

  init() {
    // Public by definition; the private key remains in the Keychain and is
    // only used by the advanced direct-SSH connection mode.
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
      switch phase {
      case .active:
        model.activate()
      case .background:
        // iOS suspends sockets in the background. Close them explicitly
        // and re-authenticate when the scene becomes active again.
        model.deactivate()
      case .inactive:
        break
      @unknown default:
        break
      }
    }
  }
}
