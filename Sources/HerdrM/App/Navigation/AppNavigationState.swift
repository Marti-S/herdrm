import Foundation
import HerdrKit
import SwiftUI

/// Window-level selection and presentation state.
///
/// The fleet runtime owns connections and sessions; this object owns where the user
/// is in the app and which transient presentation is active. `FleetStore` forwards
/// its changes while the existing views migrate to receiving narrower ViewModels.
@MainActor
final class AppNavigationState: ObservableObject {
    private static let deviceFilterKey = "device.filter"

    @Published var deviceFilter: UUID? {
        didSet {
            UserDefaults.standard.set(deviceFilter?.uuidString, forKey: Self.deviceFilterKey)
        }
    }
    @Published var selectedSpace: SpaceRef?
    @Published var selectedPane: PaneRef?
    @Published var selectedShellID: UUID?

    @Published var showAddDevice = false
    @Published var showNewAgent = false
    @Published var showNewTerminal = false
    @Published var showNewSpace = false
    @Published var showSearch = false
    @Published var showDevicePanel = false
    @Published var isFileManagerActive = false
    @Published var pendingSplitAgentFocus = false

    @Published var deviceToEdit: Device?
    @Published var sshAuthenticationRequest: SSHAuthenticationRequest?
    @Published var spaceToRename: FleetStore.SpaceEntry?
    @Published var agentToRename: FleetStore.AgentEntry?
    @Published var terminalToRename: FleetStore.TerminalEntry?
    @Published var actionError: String?
    @Published var closeRequest: FleetStore.CloseRequest?

    init(availableDevices: [Device] = []) {
        if let raw = UserDefaults.standard.string(forKey: Self.deviceFilterKey),
           let id = UUID(uuidString: raw),
           availableDevices.contains(where: { $0.id == id }) {
            deviceFilter = id
        } else {
            deviceFilter = nil
        }
    }
}
