import SwiftUI

@main
struct HerdrMobileApp: App {
  @State private var model: MobileAppModel
  @Environment(\.scenePhase) private var scenePhase

  init() {
    let dependencies = MobileAppDependencies()
    _model = State(initialValue: dependencies.model)
    // The public half of the device key, for the pairing UI and support
    // tooling. Public by definition; the private key remains in the Keychain
    // and is only used by the advanced direct-SSH connection mode.
    UserDefaults.standard.set(
      DeviceKey.authorizedKeysLine(DeviceKey.ensure()),
      forKey: "deviceKey.publicLine"
    )
    // Nerd Font symbols for agent-TUI icon glyphs (Ghostty codepoint-maps
    // the PUA ranges to this family).
    MobileGhosttyRuntime.registerBundledFonts()
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
