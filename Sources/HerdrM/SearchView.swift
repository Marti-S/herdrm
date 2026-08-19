import HerdrKit
import SwiftUI

/// Command-palette style search over agents and spaces (⌘K).
struct SearchSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    enum Result: Identifiable {
        case agent(AgentInfo)
        case space(WorkspaceInfo)

        var id: String {
            switch self {
            case .agent(let agent): return "agent-\(agent.paneID)"
            case .space(let workspace): return "space-\(workspace.workspaceID)"
            }
        }
    }

    private var results: [Result] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let agents = model.agents.filter { agent in
            q.isEmpty
                || agent.title.lowercased().contains(q)
                || agent.agent.lowercased().contains(q)
                || spaceName(agent.workspaceID).lowercased().contains(q)
        }
        let spaces = model.workspaces.filter { workspace in
            q.isEmpty || workspace.label.lowercased().contains(q)
        }
        return agents.map(Result.agent) + spaces.map(Result.space)
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
            case .agent(let agent):
                if let resource = BrandIconLoader.agentIcon(for: agent.agent) {
                    BrandIcon(resource: resource, size: 13)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                }
                Text(agent.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(agent.agent) · \(spaceName(agent.workspaceID))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            case .space(let workspace):
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(workspace.label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Space · \(model.agentCount(inSpace: workspace.workspaceID)) agents")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
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

    private func chooseHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        choose(results[highlighted])
    }

    private func choose(_ result: Result) {
        switch result {
        case .agent(let agent):
            if model.selectedSpaceID != nil && model.selectedSpaceID != agent.workspaceID {
                model.selectedSpaceID = agent.workspaceID
            }
            model.selectedPaneID = agent.paneID
        case .space(let workspace):
            model.selectSpace(workspace.workspaceID)
        }
        dismiss()
    }

    private func spaceName(_ workspaceID: String) -> String {
        model.workspaces.first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }
}
