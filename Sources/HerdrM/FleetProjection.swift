import HerdrKit

extension AppModel {
    /// Sanitized, device-qualified state for bridge clients.
    ///
    /// The caller owns the monotonically increasing revision. Keeping revision
    /// allocation outside this projection lets the current app use it now and a
    /// future background host process use the same model unchanged.
    func fleetSnapshot(revision: UInt64) -> FleetSnapshot {
        FleetSnapshot(
            revision: revision,
            devices: devices.map { device in
                let state = session(device.id)
                return FleetDeviceSnapshot(
                    device: FleetDeviceInfo(device: device),
                    connection: state.connection.fleetConnectionState,
                    agents: state.agents,
                    workspaces: state.workspaces,
                    tabs: state.tabs,
                    terminals: state.panes,
                    availableAgentKinds: state.agentCatalog.kinds
                )
            }
        )
    }
}

private extension ConnectionState {
    var fleetConnectionState: FleetConnectionState {
        switch self {
        case .idle:
            return .idle
        case .connecting:
            return .connecting
        case .connected(let version):
            return .connected(version: version)
        case .failed(let message):
            return .failed(message)
        }
    }
}
