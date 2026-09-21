import Foundation
import HerdrKit
import Observation

enum MobileFleetActionError: Error, LocalizedError {
    case deviceUnavailable
    case noWorkspace
    case noAgentKinds
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return String(localized: "The selected device is not connected.")
        case .noWorkspace:
            return String(localized: "Create a Space before starting an Agent or persistent terminal.")
        case .noAgentKinds:
            return String(localized: "This device advertises no supported Agent kinds.")
        case .malformedResponse(let detail):
            return String(localized: "The Herdr response was incomplete: \(detail)")
        }
    }
}

enum MobileActionSheet: Identifiable {
    case newSpace(deviceID: UUID?)
    case newTerminal(deviceID: UUID?, workspaceID: String?)
    case newAgent(deviceID: UUID?, workspaceID: String?)
    case renameSpace(MobileSpaceEntry)
    case renameAgent(MobileAgentEntry)
    case renameTerminal(MobileTerminalEntry)

    var id: String {
        switch self {
        case .newSpace(let deviceID):
            return "new-space-\(deviceID?.uuidString ?? "none")"
        case .newTerminal(let deviceID, let workspaceID):
            return "new-terminal-\(deviceID?.uuidString ?? "none")-\(workspaceID ?? "none")"
        case .newAgent(let deviceID, let workspaceID):
            return "new-agent-\(deviceID?.uuidString ?? "none")-\(workspaceID ?? "none")"
        case .renameSpace(let entry):
            return "rename-space-\(entry.device.id.uuidString)-\(entry.workspace.workspaceID)"
        case .renameAgent(let entry):
            return "rename-agent-\(entry.device.id.uuidString)-\(entry.agent.paneID)"
        case .renameTerminal(let entry):
            return "rename-terminal-\(entry.device.id.uuidString)-\(entry.pane.paneID)"
        }
    }
}

enum MobileCloseAction {
    case space(FleetSpaceRef)
    case pane(FleetPaneRef)
}

struct MobileCloseRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: MobileCloseAction
}

@MainActor
@Observable
final class MobileActionCoordinator {
    var sheet: MobileActionSheet?
    var closeRequest: MobileCloseRequest?
    var errorMessage: String?
    private(set) var isWorking = false

    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWorking = false }
            do {
                try await operation()
            } catch {
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    func performClose(using model: MobileAppModel) {
        guard let request = closeRequest else { return }
        closeRequest = nil
        run {
            switch request.action {
            case .space(let ref):
                try await model.closeSpace(ref)
            case .pane(let ref):
                try await model.closePane(ref)
            }
        }
    }
}

@MainActor
extension MobileAppModel {
    var actionDevices: [MobileDeviceEntry] {
        deviceEntries.filter(\.state.isConnected)
    }

    var preferredActionDeviceID: UUID? {
        if let selectedSpaceRef,
           actionDevices.contains(where: { $0.id == selectedSpaceRef.deviceID }) {
            return selectedSpaceRef.deviceID
        }
        if let selectedPaneRef,
           actionDevices.contains(where: { $0.id == selectedPaneRef.deviceID }) {
            return selectedPaneRef.deviceID
        }
        if let selectedDeviceID,
           actionDevices.contains(where: { $0.id == selectedDeviceID }) {
            return selectedDeviceID
        }
        return actionDevices.first?.id
    }

    func actionWorkspaces(deviceID: UUID) -> [WorkspaceInfo] {
        actionDevices.first { $0.id == deviceID }?.snapshot?.workspaces ?? []
    }

    func availableAgentKinds(deviceID: UUID) async throws -> [String] {
        guard let device = actionDevices.first(where: { $0.id == deviceID }),
              let transport = transport(for: deviceID)
        else { throw MobileFleetActionError.deviceUnavailable }

        if !device.availableAgentKinds.isEmpty {
            return Self.uniqueKinds(device.availableAgentKinds)
        }

        guard device.source == .direct else {
            throw MobileFleetActionError.noAgentKinds
        }
        struct Envelope: Decodable { let manifests: [AgentManifestInfo] }
        let envelope = try await transport.request(
            method: "server.agent_manifests",
            params: .object([:]),
            as: Envelope.self
        )
        let kinds = Self.uniqueKinds(envelope.manifests.map(\.agent))
        guard !kinds.isEmpty else { throw MobileFleetActionError.noAgentKinds }
        return kinds
    }

    func createSpace(
        deviceID: UUID,
        label: String,
        cwd: String
    ) async throws {
        let transport = try actionTransport(deviceID: deviceID)
        var params: [String: JSONValue] = ["focus": .bool(false)]
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLabel.isEmpty { params["label"] = .string(trimmedLabel) }
        if !trimmedCWD.isEmpty { params["cwd"] = .string(trimmedCWD) }

        let result = try await transport.request(
            method: "workspace.create",
            params: .object(params)
        )
        guard let workspaceID = result["workspace"]?["workspace_id"]?.stringValue
                ?? result["workspace_id"]?.stringValue
        else {
            throw MobileFleetActionError.malformedResponse(
                "workspace.create returned no workspace_id"
            )
        }
        let paneID = result["root_pane"]?["pane_id"]?.stringValue
        await refreshAll()
        reveal(deviceID: deviceID, workspaceID: workspaceID, paneID: paneID)
    }

    func createTerminal(
        deviceID: UUID,
        workspaceID: String,
        label: String
    ) async throws {
        guard !workspaceID.isEmpty else { throw MobileFleetActionError.noWorkspace }
        let transport = try actionTransport(deviceID: deviceID)
        var params: [String: JSONValue] = [
            "workspace_id": .string(workspaceID),
            "focus": .bool(false),
        ]
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLabel.isEmpty { params["label"] = .string(trimmedLabel) }

        let result = try await transport.request(
            method: "tab.create",
            params: .object(params)
        )
        guard let paneID = result["root_pane"]?["pane_id"]?.stringValue else {
            throw MobileFleetActionError.malformedResponse(
                "tab.create returned no root_pane.pane_id"
            )
        }
        await refreshAll()
        reveal(deviceID: deviceID, workspaceID: workspaceID, paneID: paneID)
    }

    func createAgent(
        deviceID: UUID,
        workspaceID: String,
        kind: String,
        bypassPermissions: Bool
    ) async throws {
        guard !workspaceID.isEmpty else { throw MobileFleetActionError.noWorkspace }
        let transport = try actionTransport(deviceID: deviceID)
        let trimmedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKind.isEmpty else { throw MobileFleetActionError.noAgentKinds }

        let tabResult = try await transport.request(
            method: "tab.create",
            params: .object([
                "workspace_id": .string(workspaceID),
                "label": .string(trimmedKind),
                "focus": .bool(false),
            ])
        )
        guard let paneID = tabResult["root_pane"]?["pane_id"]?.stringValue else {
            throw MobileFleetActionError.malformedResponse(
                "tab.create returned no root_pane.pane_id"
            )
        }

        let name = uniqueAgentName(kind: trimmedKind, deviceID: deviceID)
        let args = bypassPermissions
            ? MobileAgentLaunchOptions.bypassFlags(for: trimmedKind) ?? []
            : []
        do {
            _ = try await transport.request(
                method: "agent.start",
                params: .object([
                    "name": .string(name),
                    "kind": .string(trimmedKind),
                    "pane_id": .string(paneID),
                    "args": .array(args.map(JSONValue.string)),
                ])
            )
        } catch {
            _ = try? await transport.request(
                method: "pane.close",
                params: .object(["pane_id": .string(paneID)])
            )
            throw error
        }

        await refreshAll()
        reveal(deviceID: deviceID, workspaceID: workspaceID, paneID: paneID)
    }

    func renameSpace(_ entry: MobileSpaceEntry, label: String) async throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let transport = try actionTransport(deviceID: entry.device.id)
        _ = try await transport.request(
            method: "workspace.rename",
            params: .object([
                "workspace_id": .string(entry.workspace.workspaceID),
                "label": .string(trimmed),
            ])
        )
        await refreshAll()
    }

    func renameAgent(_ entry: MobileAgentEntry, label: String) async throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let transport = try actionTransport(deviceID: entry.device.id)
        _ = try await transport.request(
            method: "tab.rename",
            params: .object([
                "tab_id": .string(entry.agent.tabID),
                "label": .string(trimmed),
            ])
        )
        await refreshAll()
    }

    func renameTerminal(_ entry: MobileTerminalEntry, label: String) async throws {
        guard let tabID = entry.pane.tabID else {
            throw MobileFleetActionError.malformedResponse("terminal pane has no tab_id")
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let transport = try actionTransport(deviceID: entry.device.id)
        _ = try await transport.request(
            method: "tab.rename",
            params: .object([
                "tab_id": .string(tabID),
                "label": .string(trimmed),
            ])
        )
        await refreshAll()
    }

    func closeSpace(_ ref: FleetSpaceRef) async throws {
        let snapshot = deviceEntries.first { $0.id == ref.deviceID }?.snapshot
        let selectedWorkspaceID = selectedPaneRef.flatMap { paneRef -> String? in
            guard paneRef.deviceID == ref.deviceID else { return nil }
            return snapshot?.agents.first { $0.paneID == paneRef.paneID }?.workspaceID
                ?? snapshot?.ordinaryTerminalPanes.first {
                    $0.paneID == paneRef.paneID
                }?.workspaceID
        }

        let transport = try actionTransport(deviceID: ref.deviceID)
        _ = try await transport.request(
            method: "workspace.close",
            params: .object(["workspace_id": .string(ref.workspaceID)])
        )
        if selectedSpaceRef == ref { selectedSpaceRef = nil }
        if selectedWorkspaceID == ref.workspaceID { selectedPaneRef = nil }
        await refreshAll()
    }

    func closePane(_ ref: FleetPaneRef) async throws {
        let transport = try actionTransport(deviceID: ref.deviceID)
        _ = try await transport.request(
            method: "pane.close",
            params: .object(["pane_id": .string(ref.paneID)])
        )
        if selectedPaneRef == ref { selectedPaneRef = nil }
        await refreshAll()
    }

    private func actionTransport(deviceID: UUID) throws -> any MobileTransport {
        guard actionDevices.contains(where: { $0.id == deviceID }),
              let transport = transport(for: deviceID)
        else { throw MobileFleetActionError.deviceUnavailable }
        return transport
    }

    private func reveal(deviceID: UUID, workspaceID: String, paneID: String?) {
        if selectedDeviceID != nil { selectedDeviceID = deviceID }
        selectedSpaceRef = FleetSpaceRef(
            deviceID: deviceID,
            workspaceID: workspaceID
        )
        selectedPaneRef = paneID.map {
            FleetPaneRef(deviceID: deviceID, paneID: $0)
        }
    }

    private func uniqueAgentName(kind: String, deviceID: UUID) -> String {
        let existing = Set(
            deviceEntries.first { $0.id == deviceID }?.snapshot?.agents
                .compactMap { $0.name?.lowercased() } ?? []
        )
        var base = Self.agentNameBase(kind)
        if !existing.contains(base) { return base }
        base = String(base.prefix(27))
        for _ in 0..<16 {
            let suffix = UUID().uuidString.prefix(4).lowercased()
            let candidate = "\(base)-\(suffix)"
            if !existing.contains(candidate) { return candidate }
        }
        return "agent-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func agentNameBase(_ kind: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-"
        )
        var value = kind.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        while value.first == "-" || value.first == "_" { value.removeFirst() }
        var result = String(value)
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        if result.isEmpty || result.first?.isLetter != true {
            result = "agent-\(result)"
        }
        return String(result.prefix(32))
    }

    private static func uniqueKinds(_ kinds: [String]) -> [String] {
        var seen = Set<String>()
        return kinds.filter { kind in
            let key = kind.lowercased()
            return !kind.isEmpty && seen.insert(key).inserted
        }
    }
}

enum MobileAgentLaunchOptions {
    static func bypassFlags(for kind: String) -> [String]? {
        switch kind.lowercased() {
        case "claude": return ["--dangerously-skip-permissions"]
        case "codex": return ["--dangerously-bypass-approvals-and-sandbox"]
        case "grok": return ["--always-approve"]
        case "gemini": return ["--yolo"]
        case "opencode": return ["--auto"]
        case "cursor": return ["--force"]
        case "copilot": return ["--allow-all-tools"]
        default: return nil
        }
    }
}
