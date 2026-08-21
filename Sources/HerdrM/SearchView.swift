import HerdrKit
import SwiftUI

/// Command-palette style search over agents and spaces across all devices (⌘K).
struct SearchSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    enum Result: Identifiable {
        case agent(AppModel.AgentEntry)
        case space(AppModel.SpaceEntry)

        var id: String {
            switch self {
            case .agent(let entry): return "agent-\(entry.id)"
            case .space(let entry): return "space-\(entry.id)"
            }
        }
    }

    private var results: [Result] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let agents = model.devices.flatMap { device in
            model.session(device.id).agents.map { AppModel.AgentEntry(device: device, agent: $0) }
        }.filter { entry in
            q.isEmpty
                || entry.agent.title.lowercased().contains(q)
                || entry.agent.agent.lowercased().contains(q)
                || entry.device.name.lowercased().contains(q)
                || model.spaceName(deviceID: entry.device.id, workspaceID: entry.agent.workspaceID)
                    .lowercased().contains(q)
        }
        let spaces = model.devices.flatMap { device in
            model.session(device.id).workspaces.map { AppModel.SpaceEntry(device: device, workspace: $0) }
        }.filter { entry in
            q.isEmpty
                || entry.workspace.label.lowercased().contains(q)
                || entry.device.name.lowercased().contains(q)
        }
        // Same ordering as the sidebar (AppModel.visibleAgents): whoever needs the
        // user first, then most recently updated inside each bucket.
        let ranked = agents.sorted {
            if $0.agent.status.sortBucket != $1.agent.status.sortBucket {
                return $0.agent.status.sortBucket < $1.agent.status.sortBucket
            }
            return ($0.agent.revision ?? 0) > ($1.agent.revision ?? 0)
        }
        return ranked.map(Result.agent) + spaces.map(Result.space)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search agents and spaces…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($fieldFocused)
                    .onSubmit { chooseHighlighted() }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(results.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            if results.isEmpty {
                Text("No matches")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                row(result, isHighlighted: index == highlighted)
                                    .onTapGesture { choose(result) }
                                    .onHover { if $0 { highlighted = index } }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 320)
                    // anchor: nil moves the minimum to reveal the row — a no-op when it
                    // is already visible, so hovering never yanks the scroll position.
                    .onChange(of: highlighted) { _, index in
                        guard results.indices.contains(index) else { return }
                        proxy.scrollTo(results[index].id, anchor: nil)
                    }
                    // Reopening ⌘K starts at the top even if the sheet was left
                    // scrolled to the bottom.
                    .onAppear {
                        if let first = results.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack(spacing: 12) {
                hint("↑↓", "navigate")
                hint("↩", "open")
                Spacer()
                hint("esc", "cancel")
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
        }
        .frame(width: 440)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 4)
                .frame(height: 16)
                .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textGhost)
        }
    }

    @ViewBuilder
    private func row(_ result: Result, isHighlighted: Bool) -> some View {
        HStack(spacing: 9) {
            switch result {
            case .agent(let entry):
                if let resource = BrandIconLoader.agentIcon(for: entry.agent.agent) {
                    BrandIcon(resource: resource, size: 13)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                }
                Text(entry.agent.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                AgentStatusGlyph(status: entry.agent.status)
                Spacer(minLength: 8)
                if entry.agent.status == .blocked {
                    Text("needs input")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                }
                trailing(
                    "\(entry.agent.agent) · \(model.spaceName(deviceID: entry.device.id, workspaceID: entry.agent.workspaceID))",
                    device: entry.device
                )
            case .space(let entry):
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(entry.workspace.label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing("Space · \(model.agentCount(in: entry)) agents", device: entry.device)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHighlighted ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trailing(_ text: String, device: Device) -> some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            if model.showsDeviceBadges {
                DeviceChip(device: device)
            }
        }
    }

    private func chooseHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        choose(results[highlighted])
    }

    private func choose(_ result: Result) {
        switch result {
        case .agent(let entry):
            model.reveal(entry.ref)
        case .space(let entry):
            if let filter = model.deviceFilter, filter != entry.device.id {
                model.setDeviceFilter(nil)
            }
            model.selectSpace(entry.ref)
        }
        dismiss()
    }
}
