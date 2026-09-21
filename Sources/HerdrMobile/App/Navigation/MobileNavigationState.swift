import Foundation
import HerdrKit
import Observation

/// iOS navigation and transient presentation state.
/// Device sessions and transports live in the runtime stores, not in screen state.
@MainActor
@Observable
final class MobileNavigationState {
  /// nil means All Devices.
  var selectedDeviceID: UUID?
  var selectedSpaceRef: FleetSpaceRef?
  var selectedPaneRef: FleetPaneRef?
  var showAddConnection = false
  var actionError: String?
}
