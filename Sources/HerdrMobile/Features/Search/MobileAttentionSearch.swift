import Foundation
import HerdrKit
import Observation
import SwiftUI

struct MobileAttentionDeviceSnapshot: Equatable {
    let deviceID: UUID
    let agents: [AgentInfo]
}

struct MobileAttentionSnapshot: Equatable {
    let devices: [MobileAttentionDeviceSnapshot]
}

@MainActor
extension MobileAppModel {
    var attentionSnapshot: MobileAttentionSnapshot {
        MobileAttentionSnapshot(
            devices: deviceEntries.map {
                MobileAttentionDeviceSnapshot(
                    deviceID: $0.id,
                    agents: $0.snapshot?.agents ?? []
                )
            }
        )
    }
}

/// Client-local viewed state for the mobile fleet. Herdr publishes lifecycle
/// status but intentionally has no global "read" concept, so each UI tracks it
/// independently, matching the macOS app.
@MainActor
@Observable
final class MobileAttentionTracker {
    private(set) var unreadAgents: Set<AgentUnreadKey> = []
    private var previousStatuses: [UUID: [String: AgentStatus]] = [:]

    func apply(_ snapshot: MobileAttentionSnapshot) {
        let liveDeviceIDs = Set(snapshot.devices.map(\.deviceID))
        previousStatuses = previousStatuses.filter { liveDeviceIDs.contains($0.key) }
        unreadAgents = Set(unreadAgents.filter { liveDeviceIDs.contains($0.deviceID) })

        for device in snapshot.devices {
            unreadAgents = AgentUnread.applying(
                previous: previousStatuses[device.deviceID] ?? [:],
                agents: device.agents,
                unread: unreadAgents,
                deviceID: device.deviceID
            )
            previousStatuses[device.deviceID] = Dictionary(
                uniqueKeysWithValues: device.agents.map { ($0.paneID, $0.status) }
            )
        }
    }

    func selectionChanged(from oldValue: FleetPaneRef?, to newValue: FleetPaneRef?) {
        guard let oldValue, oldValue != newValue else { return }
        unreadAgents.remove(AgentUnreadKey(
            deviceID: oldValue.deviceID,
            paneID: oldValue.paneID
        ))
    }

    func isUnread(_ ref: FleetPaneRef) -> Bool {
        unreadAgents.contains(AgentUnreadKey(
            deviceID: ref.deviceID,
            paneID: ref.paneID
        ))
    }

    func attention(for entry: MobileSpaceEntry) -> SpaceAttention {
        let agents = entry.device.snapshot?.agents.filter {
            $0.workspaceID == entry.workspace.workspaceID
        } ?? []
        return rollup(agents: agents, deviceID: entry.device.id)
    }

    func attention(for device: MobileDeviceEntry) -> SpaceAttention {
        rollup(agents: device.snapshot?.agents ?? [], deviceID: device.id)
    }

    func attention(for devices: [MobileDeviceEntry]) -> SpaceAttention {
        SpaceAttention.rollup(devices.flatMap { device in
            (device.snapshot?.agents ?? []).map { agent in
                (
                    status: agent.status,
                    unreadDone: isUnread(FleetPaneRef(
                        deviceID: device.id,
                        paneID: agent.paneID
                    ))
                )
            }
        })
    }

    func attention(for spaces: [MobileSpaceEntry]) -> SpaceAttention {
        SpaceAttention.rollup(spaces.flatMap { entry in
            (entry.device.snapshot?.agents ?? [])
                .filter { $0.workspaceID == entry.workspace.workspaceID }
                .map { agent in
                    (
                        status: agent.status,
                        unreadDone: isUnread(FleetPaneRef(
                            deviceID: entry.device.id,
                            paneID: agent.paneID
                        ))
                    )
                }
        })
    }

    private func rollup(agents: [AgentInfo], deviceID: UUID) -> SpaceAttention {
        SpaceAttention.rollup(agents.map { agent in
            (
                status: agent.status,
                unreadDone: isUnread(FleetPaneRef(
                    deviceID: deviceID,
                    paneID: agent.paneID
                ))
            )
        })
    }
}

enum MobileSearchResult: Identifiable {
    case space(MobileSpaceEntry)
    case agent(MobileAgentEntry)
    case terminal(MobileTerminalEntry)

    var id: String {
        switch self {
        case .space(let entry):
            return "space-\(entry.ref.deviceID.uuidString)-\(entry.ref.workspaceID)"
        case .agent(let entry):
            return "agent-\(entry.ref.deviceID.uuidString)-\(entry.ref.paneID)"
        case .terminal(let entry):
            return "terminal-\(entry.ref.deviceID.uuidString)-\(entry.ref.paneID)"
        }
    }

    @MainActor
    func title(using model: MobileAppModel) -> String {
        switch self {
        case .space(let entry): return entry.workspace.label
        case .agent(let entry):
            return entry.agent.title(tabLabel: model.tabLabel(for: entry))
        case .terminal(let entry): return model.terminalLabel(for: entry)
        }
    }

    @MainActor
    func subtitle(using model: MobileAppModel) -> String {
        switch self {
        case .space(let entry):
            return "\(String(localized: "Space")) · \(entry.device.name)"
        case .agent(let entry):
            return "\(entry.agent.agent) · \(model.spaceName(deviceID: entry.device.id, workspaceID: entry.agent.workspaceID)) · \(entry.device.name)"
        case .terminal(let entry):
            return "\(model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID)) · \(entry.device.name)"
        }
    }

    var systemImage: String {
        switch self {
        case .space: return "folder"
        case .agent: return "sparkles"
        case .terminal: return "terminal"
        }
    }

    @MainActor
    func matches(_ query: String, using model: MobileAppModel) -> Bool {
        let text = "\(title(using: model)) \(subtitle(using: model))"
        return text.localizedCaseInsensitiveContains(query)
    }

    @MainActor
    func rank(using attention: MobileAttentionTracker) -> Int {
        switch self {
        case .agent(let entry):
            switch entry.agent.status {
            case .blocked: return 0
            case .done where attention.isUnread(entry.ref): return 1
            case .working: return 2
            case .done: return 3
            case .idle: return 4
            case .unknown: return 5
            }
        case .space(let entry):
            switch attention.attention(for: entry) {
            case .blocked: return 6
            case .unreadDone: return 7
            case .working: return 8
            case .none: return 9
            }
        case .terminal:
            return 10
        }
    }

    @MainActor
    func reveal(in model: MobileAppModel) {
        model.selectDevice(nil)
        switch self {
        case .space(let entry):
            model.selectSpace(entry.ref)
        case .agent(let entry):
            model.selectedSpaceRef = nil
            model.selectedPaneRef = entry.ref
        case .terminal(let entry):
            model.selectedSpaceRef = nil
            model.selectedPaneRef = entry.ref
        }
    }
}

@MainActor
private enum MobileSearchIndex {
    static func results(
        model: MobileAppModel,
        query: String,
        attention: MobileAttentionTracker
    ) -> [MobileSearchResult] {
        var values: [MobileSearchResult] = []
        for device in model.deviceEntries {
            guard let snapshot = device.snapshot else { continue }
            values.append(contentsOf: snapshot.workspaces.map {
                MobileSearchResult.space(MobileSpaceEntry(
                    ref: FleetSpaceRef(
                        deviceID: device.id,
                        workspaceID: $0.workspaceID
                    ),
                    workspace: $0,
                    device: device
                ))
            })
            values.append(contentsOf: snapshot.agents.map {
                MobileSearchResult.agent(MobileAgentEntry(
                    ref: FleetPaneRef(deviceID: device.id, paneID: $0.paneID),
                    agent: $0,
                    device: device
                ))
            })
            values.append(contentsOf: snapshot.ordinaryTerminalPanes.map {
                MobileSearchResult.terminal(MobileTerminalEntry(
                    ref: FleetPaneRef(deviceID: device.id, paneID: $0.paneID),
                    pane: $0,
                    device: device
                ))
            })
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            values = values.filter { $0.matches(trimmed, using: model) }
        }
        return values.sorted { lhs, rhs in
            let leftRank = lhs.rank(using: attention)
            let rightRank = rhs.rank(using: attention)
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.title(using: model).localizedStandardCompare(
                rhs.title(using: model)
            ) == .orderedAscending
        }
    }
}

struct MobileSearchSheet: View {
    let model: MobileAppModel
    let attention: MobileAttentionTracker
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [MobileSearchResult] {
        MobileSearchIndex.results(
            model: model,
            query: query,
            attention: attention
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { result in
                        Button {
                            result.reveal(in: model)
                            dismiss()
                        } label: {
                            MobileSearchResultRow(
                                result: result,
                                model: model,
                                attention: attention
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(String(localized: "Search Fleet"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: String(localized: "Spaces, Agents, terminals, devices")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}

private struct MobileSearchResultRow: View {
    let result: MobileSearchResult
    let model: MobileAppModel
    let attention: MobileAttentionTracker

    var body: some View {
        HStack(spacing: 10) {
            leadingGlyph
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title(using: model))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(result.subtitle(using: model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch result {
        case .agent(let entry):
            MobileStatusGlyph(status: entry.agent.status)
                .overlay(alignment: .bottomTrailing) {
                    if attention.isUnread(entry.ref) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                    }
                }
        case .space(let entry):
            MobileAttentionGlyph(
                attention: attention.attention(for: entry),
                fallbackSystemImage: "folder"
            )
        case .terminal:
            Image(systemName: result.systemImage)
                .foregroundStyle(.secondary)
        }
    }
}
