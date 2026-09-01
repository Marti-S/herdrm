import Foundation
import HerdrKit
import SwiftUI

private struct PaneReadEnvelope: Decodable {
    let read: TerminalReadResult
}

extension MobileTransport {
    /// Reads a bounded, terminal-derived transcript without changing the
    /// attached application's viewport.
    func readPaneTranscript(
        paneID: String,
        lines: Int = 250,
        source: TerminalReadSource = .recentUnwrapped
    ) async throws -> TerminalReadResult {
        let boundedLines = max(1, min(lines, 250))
        let envelope: PaneReadEnvelope = try await request(
            method: "pane.read",
            params: .object([
                "pane_id": .string(paneID),
                "source": .string(source.rawValue),
                "lines": .number(Double(boundedLines)),
                "format": .string(TerminalReadFormat.text.rawValue),
                "strip_ansi": .bool(true),
            ]),
            as: PaneReadEnvelope.self
        )
        return envelope.read
    }
}

/// Adapts Herdr's current terminal snapshot API to the semantic transcript
/// boundary. The explicit `.terminal` role prevents terminal text from being
/// misrepresented as structured assistant messages.
struct HerdrPaneTranscriptProvider: AgentTranscriptProvider {
    let transport: any MobileTransport
    let paneID: String
    let lineLimit: Int
    let pollInterval: Duration

    init(
        transport: any MobileTransport,
        paneID: String,
        lineLimit: Int = 250,
        pollInterval: Duration = .milliseconds(900)
    ) {
        self.transport = transport
        self.paneID = paneID
        self.lineLimit = max(1, min(lineLimit, 250))
        self.pollInterval = pollInterval
    }

    func snapshot() async throws -> TranscriptSnapshot {
        let read = try await transport.readPaneTranscript(
            paneID: paneID,
            lines: min(lineLimit, 100)
        )
        return Self.makeSnapshot(read, paneID: paneID)
    }

    func updates(
        after sequence: UInt64?
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let transport = transport
        let paneID = paneID
        let lineLimit = lineLimit
        let pollInterval = pollInterval

        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                var lastSequence = sequence
                var lastText: String?
                do {
                    while !Task.isCancelled {
                        let read = try await transport.readPaneTranscript(
                            paneID: paneID,
                            lines: lineLimit
                        )
                        if lastSequence != read.revision || lastText != read.text {
                            lastSequence = read.revision
                            lastText = read.text
                            continuation.yield(
                                .snapshot(Self.makeSnapshot(read, paneID: paneID))
                            )
                        }
                        try await Task.sleep(for: pollInterval)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }


    private static func makeSnapshot(
        _ read: TerminalReadResult,
        paneID: String
    ) -> TranscriptSnapshot {
        let providerID = "herdr-pane:\(paneID)"
        let readableText = readableTerminalText(read.text)
        let items: [ConversationItem]
        if readableText.isEmpty {
            items = []
        } else {
            items = [
                ConversationItem(
                    id: "\(providerID):terminal",
                    sequence: read.revision,
                    role: .terminal,
                    blocks: [.terminalText(readableText)],
                    state: .complete
                )
            ]
        }
        return TranscriptSnapshot(
            providerID: providerID,
            source: .terminalRecentUnwrapped,
            sequence: read.revision,
            items: items,
            isTruncated: read.truncated
        )
    }

    /// Flattens terminal-only framing without inferring message roles. The raw
    /// terminal remains available from the screen's Terminal mode.
    private static func readableTerminalText(_ text: String) -> String {
        let decoration = CharacterSet(charactersIn: "─━═│┃┄┅┈┉╭╮╰╯├┤┬┴┼_")
        let edgeDecoration = CharacterSet(charactersIn: "│┃╭╮╰╯├┤┬┴┼")
        var output: [String] = []
        var previousWasBlank = true

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            while line.last?.isWhitespace == true { line.removeLast() }
            let visible = line.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }
            let decorationCount = visible.reduce(into: 0) { count, scalar in
                if decoration.contains(scalar) { count += 1 }
            }
            if visible.count >= 3, decorationCount * 5 >= visible.count * 4 {
                line = ""
            } else {
                let withoutBorder = line.trimmingCharacters(in: edgeDecoration)
                if withoutBorder != line {
                    line = withoutBorder.trimmingCharacters(in: .whitespaces)
                }
            }

            if line.isEmpty {
                guard !previousWasBlank else { continue }
                previousWasBlank = true
            } else {
                previousWasBlank = false
            }
            output.append(line)
        }

        while output.last?.isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }

}

@MainActor
final class ConversationReaderStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var snapshot: TranscriptSnapshot?
    @Published private(set) var hasNewOutput = false
    @Published private(set) var updateErrorMessage: String?
    @Published private(set) var isPinnedToLatest = true
    @Published private(set) var contentVersion: UInt64 = 0

    private let provider: any AgentTranscriptProvider
    private var updateTask: Task<Void, Never>?
    private var pendingSnapshot: TranscriptSnapshot?
    private var started = false

    init(provider: any AgentTranscriptProvider) {
        self.provider = provider
    }

    var items: [ConversationItem] { snapshot?.items ?? [] }
    var revision: UInt64 { snapshot?.sequence ?? 0 }
    var isTruncated: Bool { snapshot?.isTruncated ?? false }
    var source: TranscriptSource? { snapshot?.source }

    func start() async {
        guard !started else { return }
        started = true
        updateErrorMessage = nil
        if snapshot == nil {
            loadState = .loading
        }

        do {
            let initial = try await provider.snapshot()
            guard started, !Task.isCancelled else { return }
            install(initial, force: true)
            loadState = .ready
            startUpdates(after: initial.sequence)
        } catch is CancellationError {
            started = false
        } catch {
            guard started else { return }
            started = false
            loadState = .failed(Self.presentation(error))
        }
    }

    func stop() {
        started = false
        updateTask?.cancel()
        updateTask = nil
    }

    func retry() {
        stop()
        Task { await start() }
    }

    func refresh() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let next = try await provider.snapshot()
                install(next, force: isPinnedToLatest)
                loadState = .ready
                updateErrorMessage = nil
            } catch {
                updateErrorMessage = Self.presentation(error)
            }
        }
    }

    func setPinnedToLatest(_ pinned: Bool) {
        isPinnedToLatest = pinned
        if pinned {
            resumeFollowing()
        }
    }

    func resumeFollowing() {
        isPinnedToLatest = true
        if let pendingSnapshot {
            snapshot = pendingSnapshot
            contentVersion &+= 1
            self.pendingSnapshot = nil
        }
        hasNewOutput = false
    }

    private func startUpdates(after sequence: UInt64?) {
        updateTask?.cancel()
        let stream = provider.updates(after: sequence)
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    guard started, !Task.isCancelled else { return }
                    receive(event)
                }
            } catch is CancellationError {
                return
            } catch {
                guard started else { return }
                updateErrorMessage = Self.presentation(error)
            }
        }
    }

    private func receive(_ event: TranscriptEvent) {
        let base = pendingSnapshot
            ?? snapshot
            ?? TranscriptSnapshot.empty(
                providerID: "pending",
                source: .semantic
            )
        install(base.applying(event), force: false)
    }

    private func install(_ next: TranscriptSnapshot, force: Bool) {
        if force || isPinnedToLatest || snapshot == nil {
            snapshot = next
            contentVersion &+= 1
            pendingSnapshot = nil
            hasNewOutput = false
        } else {
            pendingSnapshot = next
            hasNewOutput = next.sequence != snapshot?.sequence
                || next.items != snapshot?.items
                || next.isTruncated != snapshot?.isTruncated
        }
    }

    private static func presentation(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}


struct ConversationReaderView: View {
    @ObservedObject var store: ConversationReaderStore

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
                await store.start()
                await Task.yield()
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onDisappear { store.stop() }
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
            LazyVStack(alignment: .leading, spacing: 18) {
                transcriptNotices
                transcriptContent
                Color.clear
                    .frame(height: 1)
                    .id(bottomID)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.top, 14)
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
            Label(
                String(localized: "Terminal-derived transcript"),
                systemImage: "text.and.command.macwindow"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if store.isTruncated {
            Label(
                String(localized: "Showing the latest terminal history"),
                systemImage: "ellipsis"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let error = store.updateErrorMessage {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                Text(error)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(String(localized: "Retry")) { store.retry() }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        switch store.loadState {
        case .idle, .loading where store.items.isEmpty:
            HStack {
                Spacer()
                ProgressView()
                    .tint(.white)
                    .padding(.top, 40)
                Spacer()
            }

        case .failed(let message) where store.items.isEmpty:
            EmptyConversationView(
                title: String(localized: "Could Not Load Conversation"),
                message: message,
                actionTitle: String(localized: "Retry"),
                action: store.retry
            )

        default:
            if store.items.isEmpty {
                EmptyConversationView(
                    title: String(localized: "No Conversation Output"),
                    message: String(localized: "Output will appear here when the agent writes to its terminal."),
                    actionTitle: String(localized: "Refresh"),
                    action: store.refresh
                )
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
            Label(
                store.hasNewOutput
                    ? String(localized: "New output")
                    : String(localized: "Latest"),
                systemImage: "arrow.down"
            )
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(height: 38)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(String(localized: "Scroll to latest output"))
    }
}

private struct ConversationItemView: View {
    let item: ConversationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                TranscriptBlockView(block: block, role: item.role)
            }
        }
        .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
        .padding(item.role == .user ? 12 : 0)
        .background {
            if item.role == .user {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(0.10))
            }
        }
        .padding(.leading, item.role == .user ? 44 : 0)
        .opacity(item.state == .failed ? 0.65 : 1)
    }
}

private struct TranscriptBlockView: View {
    let block: TranscriptContentBlock
    let role: ConversationRole

    @ViewBuilder
    var body: some View {
        switch block {
        case .markdown(let markdown):
            markdownText(markdown)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

        case .tool(let name, let status, let detail):
            VStack(alignment: .leading, spacing: 6) {
                Label(name, systemImage: status.systemImage)
                    .font(.callout.weight(.semibold))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

        case .notice(let text):
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .terminalText(let text):
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markdownText(_ markdown: String) -> Text {
        guard let attributed = try? AttributedString(markdown: markdown) else {
            return Text(markdown)
        }
        return Text(attributed)
    }
}

private extension TranscriptToolStatus {
    var systemImage: String {
        switch self {
        case .pending: return "clock"
        case .running: return "progress.indicator"
        case .succeeded: return "checkmark.circle"
        case .failed: return "xmark.circle"
        }
    }
}

private struct EmptyConversationView: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}
