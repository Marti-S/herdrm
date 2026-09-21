/// Composition root for iOS runtime state.
/// The model owns device sessions across screen reconstruction and scene changes.
@MainActor
final class MobileAppDependencies {
  let model: MobileAppModel

  init() {
    model = MobileAppModel()
  }

  init(model: MobileAppModel) {
    self.model = model
  }
}
