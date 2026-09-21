/// Composition root for process-lifetime macOS state.
/// Feature ViewModels receive narrower collaborators from here as they are created;
/// the fleet store remains process-owned so window closure cannot end connections.
@MainActor
final class AppDependencies {
    let fleetStore: FleetStore

    init() {
        fleetStore = FleetStore()
    }

    init(fleetStore: FleetStore) {
        self.fleetStore = fleetStore
    }
}
