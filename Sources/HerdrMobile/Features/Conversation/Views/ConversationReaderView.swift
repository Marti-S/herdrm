import Foundation
import HerdrKit
import SwiftUI

struct ConversationReaderView: View {
    @ObservedObject var store: ConversationReaderViewModel

    @State private var isNearBottom = true
    @State private var userDrivenScroll = false

    private let bottomID = "mobile-conversation-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                transcriptScrollView

                if !isNearBottom || store.hasNewOutput {
                    latestButton(proxy: proxy)
                        .padding(16)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .task {
                await store.run()
            }
            .onChange(of: store.loadState) { _, state in
                guard state == .ready else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onChange(of: store.contentVersion) { _, _ in
                guard store.isPinnedToLatest, !userDrivenScroll else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .animation(.easeOut(duration: 0.18), value: store.hasNewOutput)
        }
    }


    private var transcriptScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                transcriptNotices
                transcriptContent
                Color.clear
                    .frame(height: 1)
                    .id(bottomID)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .textSelection(.enabled)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY < 72
        } action: { _, nearBottom in
            isNearBottom = nearBottom
            if nearBottom {
                store.setPinnedToLatest(true)
            } else if userDrivenScroll {
                store.setPinnedToLatest(false)
            }
        }
        .onScrollPhaseChange { _, newPhase in
            switch newPhase {
            case .tracking, .interacting, .decelerating:
                userDrivenScroll = true
            case .idle:
                userDrivenScroll = false
                if isNearBottom {
                    store.setPinnedToLatest(true)
                }
            case .animating:
                break
            @unknown default:
                break
            }
        }
        .refreshable { store.refresh() }
    }

    @ViewBuilder
    private var transcriptNotices: some View {
        if store.source == .terminalRecentUnwrapped {
            Text("Terminal-derived transcript")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }

        if store.isTruncated {
            Text("Showing the latest terminal history")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }

        if let error = store.updateErrorMessage {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                Text(error)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(String(localized: "Retry")) { store.retry() }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        switch store.loadState {
        case .idle, .loading where store.items.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)

        case .failed(let message) where store.items.isEmpty:
            ContentUnavailableView {
                Label(String(localized: "Could Not Load Conversation"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "Retry"), action: store.retry)
            }

        default:
            if store.items.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Conversation Output"), systemImage: "text.bubble")
                } description: {
                    Text("Output will appear here when the agent writes to its terminal.")
                } actions: {
                    Button(String(localized: "Refresh"), action: store.refresh)
                }
            } else {
                ForEach(store.items) { item in
                    ConversationItemView(item: item)
                }
            }
        }
    }

    private func latestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            store.resumeFollowing()
            Task { @MainActor in
                await Task.yield()
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        } label: {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(
            store.hasNewOutput
                ? String(localized: "New output — scroll to latest")
                : String(localized: "Scroll to latest output")
        )
    }
}

/// ChatGPT-style rows: assistant text is bare body text, tool activity is a
/// single secondary-colored line with a glyph, and only the user's own
/// message gets a bubble. No custom colors — system hierarchy only.
private struct ConversationItemView: View {
    let item: ConversationItem

    var body: some View {
        Group {
            if item.role == .user {
                userBubble
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                        TranscriptBlockView(block: block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(item.state == .failed ? 0.6 : 1)
    }

    private var userBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                TranscriptBlockView(block: block)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
        .padding(.vertical, 12)
    }
}

private struct TranscriptBlockView: View {
    let block: TranscriptContentBlock

    @State private var expanded = false

    @ViewBuilder
    var body: some View {
        switch block {
        case .markdown(let markdown):
            markdownText(markdown)
                .font(.body)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)

        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(12)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.vertical, 6)

        case .tool(let name, let status, let detail):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: status.glyph(for: name))
                        .font(.body)
                        .frame(width: 20)
                        .foregroundStyle(status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .symbolEffect(.pulse, isActive: status == .running)
                    Text(toolSummary(name: name, detail: detail))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 1)
                        .truncationMode(.tail)
                }
                if expanded, let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 32)
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }

        case .notice(let text):
            Text(text)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 6)

        case .terminalText(let text):
            Text(text)
                .font(.body)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        }
    }

    /// One line: the tool name is the verb, the first detail line is the object.
    private func toolSummary(name: String, detail: String?) -> String {
        guard let firstLine = detail?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespaces),
            !firstLine.isEmpty
        else { return name }
        return "\(name) \(firstLine)"
    }

    private func markdownText(_ markdown: String) -> Text {
        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return Text(markdown)
        }
        return Text(attributed)
    }
}

private extension TranscriptToolStatus {
    /// Glyph by tool family; status only changes tint and animation.
    func glyph(for toolName: String) -> String {
        let lowered = toolName.lowercased()
        if lowered.contains("bash") || lowered.contains("shell") || lowered.contains("terminal") {
            return "terminal"
        }
        if lowered.contains("edit") || lowered.contains("write") || lowered.contains("patch") {
            return "pencil"
        }
        if lowered.contains("read") || lowered.contains("cat") {
            return "doc.text"
        }
        if lowered.contains("search") || lowered.contains("grep") || lowered.contains("find")
            || lowered.contains("glob") || lowered.contains("locate") {
            return "magnifyingglass"
        }
        if lowered.contains("web") || lowered.contains("fetch") || lowered.contains("http")
            || lowered.contains("browse") {
            return "globe"
        }
        if lowered.contains("agent") || lowered.contains("task") || lowered.contains("workflow") {
            return "person.2"
        }
        return "circle.dotted"
    }
}
