import Foundation
import HerdrKit

extension FleetBridgeServer {
    func performRPC(_ request: FleetBridgeRPCRequest) async throws -> JSONValue {
        guard let model else {
            throw FleetBridgeHostError.invalidRequest("HerdrM is not ready.")
        }
        guard let device = model.device(request.deviceID) else {
            throw FleetBridgeHostError.unknownDevice(request.deviceID)
        }
        guard case .object(let params) = request.params else {
            throw FleetBridgeHostError.invalidRequest("RPC params must be an object.")
        }
        let service = model.service(for: device)

        switch request.method {
        case "ping":
            guard case .connected(let version) = model.session(device.id).connection else {
                throw FleetBridgeHostError.invalidRequest("The device is not connected.")
            }
            return .object([
                "version": .string(version),
                "protocol": .number(Double(HerdrService.minimumProtocolVersion)),
            ])

        case "session.snapshot":
            let snapshot = deviceSessionSnapshot(device: device, model: model)
            return .object(["snapshot": try jsonValue(snapshot)])

        case "agent.prompt":
            try await service.prompt(
                target: try requiredString(params, "target"),
                text: try requiredString(params, "text")
            )
            return .object([:])

        case "pane.send_input":
            let paneID = try requiredString(params, "pane_id")
            if let text = optionalString(params, "text") {
                try await service.sendInput(paneID: paneID, text: text)
            } else if let keys = optionalStrings(params, "keys") {
                try await service.sendKeys(paneID: paneID, keys: keys)
            } else {
                throw FleetBridgeHostError.invalidRequest(
                    "pane.send_input requires text or keys."
                )
            }
            return .object([:])

        case "workspace.create":
            let created = try await service.createWorkspace(
                label: optionalString(params, "label"),
                cwd: optionalString(params, "cwd")
            )
            var value: [String: JSONValue] = [
                "workspace": .object(["workspace_id": .string(created.workspaceID)])
            ]
            if let paneID = created.rootPaneID {
                value["root_pane"] = .object(["pane_id": .string(paneID)])
            }
            return .object(value)

        case "workspace.rename":
            try await service.renameWorkspace(
                workspaceID: try requiredString(params, "workspace_id"),
                label: try requiredString(params, "label")
            )
            return .object([:])

        case "workspace.close":
            try await service.closeWorkspace(
                workspaceID: try requiredString(params, "workspace_id")
            )
            return .object([:])

        case "tab.create":
            let paneID = try await service.createTab(
                workspaceID: optionalString(params, "workspace_id"),
                cwd: optionalString(params, "cwd"),
                label: optionalString(params, "label")
            )
            return .object(["root_pane": .object(["pane_id": .string(paneID)])])

        case "tab.rename":
            try await service.renameTab(
                tabID: try requiredString(params, "tab_id"),
                label: try requiredString(params, "label")
            )
            return .object([:])

        case "pane.close":
            try await service.closePane(paneID: try requiredString(params, "pane_id"))
            return .object([:])

        case "agent.rename":
            try await service.renameAgent(
                target: try requiredString(params, "target"),
                name: try requiredString(params, "name")
            )
            return .object([:])

        case "agent.start":
            try await service.startAgent(
                name: try requiredString(params, "name"),
                kind: try requiredString(params, "kind"),
                paneID: try requiredString(params, "pane_id"),
                args: optionalStrings(params, "args") ?? []
            )
            return .object([:])

        default:
            throw FleetBridgeHostError.unsupportedMethod(request.method)
        }
    }
}
