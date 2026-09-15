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

/// Thrown when one transcript read outlives its deadline.
private struct TranscriptLoadTimeout: Error {}

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
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var updateTask: Task<Void, Never>?
    private var pendingSnapshot: TranscriptSnapshot?
    /// Views currently showing this store. The store is cached per pane and a
    /// replacement screen's `.task` can start before the old screen's task is
    /// cancelled, so lifecycle is counted rather than toggled.
    private var viewerCount = 0

    init(provider: any AgentTranscriptProvider) {
        self.provider = provider
    }

    var items: [ConversationItem] { snapshot?.items ?? [] }
    var revision: UInt64 { snapshot?.sequence ?? 0 }
    var isTruncated: Bool { snapshot?.isTruncated ?? false }
    var source: TranscriptSource? { snapshot?.source }

    /// Keeps the transcript live for as long as the calling task runs. Bind
    /// it to the view with `.task { await store.run() }`; cancellation is the
    /// only detach signal.
    func run() async {
        attach()
        defer { detach() }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    private func attach() {
        viewerCount += 1
        if viewerCount == 1 { beginLoading() }
    }

    private func detach() {
        viewerCount = max(0, viewerCount - 1)
        if viewerCount == 0 { cancelWork() }
    }

    private var isRunning: Bool { loadTask != nil || updateTask != nil }

    /// A single first read may queue behind other SSH work on the same
    /// connection (`SessionDriver` serializes operations FIFO and the wait is
    /// not cancellable), so an attempt is abandoned at this deadline and
    /// retried instead of spinning forever.
    static let loadAttemptTimeout: Duration = .seconds(6)
    private static let loadRetryDelay: Duration = .seconds(1)

    private func beginLoading() {
        guard !isRunning else { return }
        updateErrorMessage = nil
        if snapshot == nil {
            loadState = .loading
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            guard let self else { return }
            // Only clear the handle this task owns: a cancelled task can run
            // its cleanup after the next attempt has already been stored.
            defer { if loadGeneration == generation { loadTask = nil } }
            var attempt = 0
            while !Task.isCancelled, viewerCount > 0, loadGeneration == generation {
                attempt += 1
                do {
                    let initial = try await Self.withTimeout(Self.loadAttemptTimeout) {
                        try await self.provider.snapshot()
                    }
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    install(initial, force: true)
                    loadState = .ready
                    updateErrorMessage = nil
                    startUpdates(after: initial.sequence)
                    return
                } catch is CancellationError {
                    return
                } catch is TranscriptLoadTimeout {
                    // Keep the spinner and try again; the connection is busy,
                    // not broken.
                    guard !Task.isCancelled else { return }
                    if attempt >= 3 {
                        updateErrorMessage = String(localized: "Still loading — the connection is busy.")
                    }
                } catch {
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    loadState = .failed(Self.presentation(error))
                    return
                }
                do { try await Task.sleep(for: Self.loadRetryDelay) } catch { return }
            }
        }
    }

    /// Runs `operation` but stops waiting after `duration`. The abandoned work
    /// is cancelled; uncancellable native waits simply finish unobserved.
    private static func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TranscriptLoadTimeout()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TranscriptLoadTimeout() }
            return result
        }
    }

    private func cancelWork() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        updateTask?.cancel()
        updateTask = nil
        if loadState == .loading, snapshot == nil {
            // Never leave a detached store looking busy; the next viewer
            // starts a fresh load.
            loadState = .idle
        }
    }

    func retry() {
        cancelWork()
        updateErrorMessage = nil
        if viewerCount > 0 { beginLoading() }
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

    private static let updateRetryDelay: Duration = .seconds(3)

    /// Follows the provider stream and, if it ends or fails while a viewer is
    /// still attached, resumes from the last known sequence after a pause.
    private func startUpdates(after sequence: UInt64?) {
        updateTask?.cancel()
        let stream = provider.updates(after: sequence)
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    receive(event)
                }
                guard !Task.isCancelled else { return }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                updateErrorMessage = Self.presentation(error)
            }
            do {
                try await Task.sleep(for: Self.updateRetryDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, viewerCount > 0 else { return }
            startUpdates(after: revision)
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
