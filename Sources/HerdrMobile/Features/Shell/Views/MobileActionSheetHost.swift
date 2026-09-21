import SwiftUI

struct MobileActionSheetHost: View {
    let route: MobileActionSheet
    let model: MobileAppModel
    let actions: MobileActionCoordinator

    @ViewBuilder
    var body: some View {
        switch route {
        case .newSpace(let deviceID):
            MobileNewSpaceSheet(
                model: model,
                actions: actions,
                initialDeviceID: deviceID
            )
        case .newTerminal(let deviceID, let workspaceID):
            MobileNewTerminalSheet(
                model: model,
                actions: actions,
                initialDeviceID: deviceID,
                initialWorkspaceID: workspaceID
            )
        case .newAgent(let deviceID, let workspaceID):
            MobileNewAgentSheet(
                model: model,
                actions: actions,
                initialDeviceID: deviceID,
                initialWorkspaceID: workspaceID
            )
        case .renameSpace(let entry):
            MobileRenameSheet(
                title: String(localized: "Rename Space"),
                prompt: String(localized: "Space name"),
                initialValue: entry.workspace.label,
                actions: actions
            ) { value in
                try await model.renameSpace(entry, label: value)
            }
        case .renameAgent(let entry):
            MobileRenameSheet(
                title: String(localized: "Rename Agent"),
                prompt: String(localized: "Agent display name"),
                initialValue: entry.agent.title(tabLabel: model.tabLabel(for: entry)),
                actions: actions
            ) { value in
                try await model.renameAgent(entry, label: value)
            }
        case .renameTerminal(let entry):
            MobileRenameSheet(
                title: String(localized: "Rename Terminal"),
                prompt: String(localized: "Terminal name"),
                initialValue: model.terminalLabel(for: entry),
                actions: actions
            ) { value in
                try await model.renameTerminal(entry, label: value)
            }
        }
    }
}
