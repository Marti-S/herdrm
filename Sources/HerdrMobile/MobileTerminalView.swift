import HerdrKit
import SwiftTerm
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One live transport-neutral terminal session, pumped into a SwiftTerm view.
///
/// The session outlives view updates and ends when its transport reports
/// orderly closure, ownership loss, or a network failure. Direct SSH and the
/// Mac bridge expose the same ordered terminal-frame surface.
///
/// Mobile terminals are display-first: the live pane renders, but typing can
/// go through the composer (`agent.prompt`) and key bar (`pane.send_input`).
/// Raw keyboard input requires an explicit control lease.
@MainActor
final class MobileAttachSession: ObservableObject {
    enum Status: Equatable {
        case connecting
        case running
        case ended(String)
    }

    @Published var status: Status = .connecting
    @Published private(set) var mode: TerminalSessionMode = .observe
    @Published private(set) var terminalScrollPosition: Double = 1
    @Published private(set) var isAtLatestOutput = true

    let transport: MobileTransport
    let target: TerminalAttachTarget
    let paneID: String

    private lazy var inputQueue: TerminalInputQueue = {
        let transport = transport
        return TerminalInputQueue(
            generation: lifecycleGeneration,
            sendTerminal: { [weak self] data in
                guard let terminalSession = self?.terminalSession else { return }
                try await terminalSession.send(data)
            },
            resizeTerminal: { [weak self] size in
                guard let terminalSession = self?.terminalSession else { return }
                try await terminalSession.resize(size)
            },
            sendSemantic: { method, params in
                _ = try await transport.request(method: method, params: params)
            }
        )
    }()

    private var terminalSession: (any TerminalSession)?
    private var outputBatcher: TerminalOutputBatcher?
    private var terminalFeedSender: TerminalFeedSender?
    private var startTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var lastSize = TerminalSize(columns: 80, rows: 24)
    private var pendingScrollRestore: Double?
    weak var terminalView: TerminalView?

    init(transport: MobileTransport, target: TerminalAttachTarget, paneID: String) {
        self.transport = transport
        self.target = target
        self.paneID = paneID
    }

    var agentPaneID: String? {
        if case .agent(let paneID) = target { return paneID }
        return nil
    }

    var isControlling: Bool {
        mode.access == .control && status == .running
    }

    func attachTerminalView(_ view: TerminalView) {
        terminalView = view
        terminalFeedSender = view.feedSender
        terminalDidScroll(to: view.scrollPosition)
    }

    func detachTerminalView(_ view: TerminalView) {
        guard terminalView === view else { return }
        terminalView = nil
        terminalFeedSender = nil
    }

    func start(
        columns: Int,
        rows: Int,
        mode requestedMode: TerminalSessionMode = .observe
    ) {
        guard terminalSession == nil, startTask == nil else { return }

        let size = TerminalSize(
            columns: max(columns, 20),
            rows: max(rows, 5)
        )
        lastSize = size
        mode = requestedMode
        status = .connecting
        lifecycleGeneration &+= 1
        inputQueue.updateGeneration(lifecycleGeneration)
        let generation = lifecycleGeneration
        let outputBatcher = TerminalOutputBatcher { [weak self] data in
            guard let self, self.lifecycleGeneration == generation else { return }
            self.feed(data, generation: generation)
        }
        self.outputBatcher = outputBatcher

        startTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.lifecycleGeneration == generation {
                    self.startTask = nil
                }
            }
            do {
                let terminalSession = try await transport.openTerminalSession(
                    target: target,
                    mode: requestedMode,
                    size: size
                )
                guard !Task.isCancelled, self.lifecycleGeneration == generation else {
                    await terminalSession.close()
                    return
                }
                self.terminalSession = terminalSession
                self.status = .running
                self.pump(
                    terminalSession,
                    outputBatcher: outputBatcher,
                    generation: generation
                )
            } catch {
                await outputBatcher.cancel()
                guard !Task.isCancelled, self.lifecycleGeneration == generation else { return }
                self.outputBatcher = nil
                self.status = .ended(Self.presentation(error))
            }
        }
    }

    func observe() {
        restart(mode: .observe)
    }

    func requestControl(takeover: Bool) {
        restart(mode: .control(takeover: takeover))
    }

    private func restart(
        mode: TerminalSessionMode,
        preserveScrollPosition: Bool = false
    ) {
        let size = lastSize
        let restorePosition = preserveScrollPosition && !isAtLatestOutput
            ? terminalScrollPosition
            : nil
        stop()
        pendingScrollRestore = restorePosition
        start(columns: size.columns, rows: size.rows, mode: mode)
    }

    private func pump(
        _ terminalSession: any TerminalSession,
        outputBatcher: TerminalOutputBatcher,
        generation: UInt64
    ) {
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            var endingReason = String(localized: "Session ended")
            do {
                while !Task.isCancelled {
                    guard let frame = try await terminalSession.read() else { break }
                    guard !frame.bytes.isEmpty else { continue }
                    await outputBatcher.append(frame.bytes)
                }
            } catch {
                endingReason = Self.presentation(error)
            }

            await outputBatcher.finish()
            await terminalSession.close()
            guard !Task.isCancelled else { return }
            await self?.terminalPumpEnded(
                generation: generation,
                reason: endingReason
            )
        }
    }

    private func feed(_ data: Data, generation: UInt64) {
        guard lifecycleGeneration == generation, let terminalFeedSender else { return }
        let bytes = [UInt8](data)
        terminalFeedSender.feed(byteArray: bytes[...])
        firstFrameDidArrive(generation: generation)
    }

    private func firstFrameDidArrive(generation: UInt64) {
        guard lifecycleGeneration == generation,
              let position = pendingScrollRestore
        else { return }
        pendingScrollRestore = nil

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.lifecycleGeneration == generation,
                  let terminalView = self.terminalView
            else { return }
            terminalView.scroll(toPosition: position)
            self.terminalDidScroll(to: position)
        }
    }

    private func terminalPumpEnded(generation: UInt64, reason: String) {
        guard lifecycleGeneration == generation else { return }
        terminalSession = nil
        outputBatcher = nil
        readTask = nil
        if case .running = status {
            status = .ended(reason)
        }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard terminalSession != nil, mode.allowsInput else { return }
        inputQueue.enqueueTerminal(Data(bytes), generation: lifecycleGeneration)
    }

    /// Sends named keys through Herdr's RPC so the server can encode them for
    /// the terminal's current keyboard protocol state.
    func sendKeys(_ keys: [String]) -> TerminalInputQueue.SemanticTicket {
        inputQueue.submitSemantic(
            method: "pane.send_input",
            params: .object([
                "pane_id": .string(paneID),
                "keys": .array(keys.map { .string($0) }),
            ])
        )
    }

    /// Sends a semantic agent prompt. This remains available to observers
    /// because it is separate from the raw terminal input lease.
    func prompt(_ text: String) throws -> TerminalInputQueue.SemanticTicket {
        guard let agentPaneID else { throw MobileTerminalInputError.agentUnavailable }
        return inputQueue.submitSemantic(
            method: "agent.prompt",
            params: .object([
                "target": .string(agentPaneID),
                "text": .string(text),
            ])
        )
    }


    func stageAttachment(_ attachment: MobileAttachmentPayload) async throws -> String {
        try await transport.stageAttachment(attachment)
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        let size = TerminalSize(columns: columns, rows: rows)
        let previousSize = lastSize
        guard size != previousSize else { return }
        lastSize = size

        guard terminalSession != nil else { return }
        if mode.allowsResize {
            inputQueue.enqueueResize(size, generation: lifecycleGeneration)
            return
        }

        // Observer frames own their remote grid. Keyboard presentation and a
        // growing composer change only the local row count, so reconnecting for
        // those changes discards momentum and can reset local scrollback.
        // Reopen only when width changes (normally rotation or split resizing),
        // and preserve the reader's normalized scroll position across it.
        guard size.columns != previousSize.columns else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.restart(mode: .observe, preserveScrollPosition: true)
        }
    }

    func terminalDidScroll(to position: Double) {
        terminalScrollPosition = position
        guard let terminalView else {
            isAtLatestOutput = true
            return
        }

        let maximumOffset = max(
            0,
            terminalView.contentSize.height
                - terminalView.bounds.height
                + terminalView.adjustedContentInset.bottom
        )
        let threshold = max(
            8,
            min(44, terminalView.bounds.height * 0.08)
        )
        isAtLatestOutput = maximumOffset <= threshold
            || terminalView.contentOffset.y >= maximumOffset - threshold
    }

    func scrollToLatest() {
        guard let terminalView else { return }
        terminalView.scroll(toPosition: 1)
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.terminalDidScroll(to: 1)
        }
    }

    func stop() {
        lifecycleGeneration &+= 1
        inputQueue.updateGeneration(lifecycleGeneration)
        pendingScrollRestore = nil
        resizeTask?.cancel()
        resizeTask = nil
        startTask?.cancel()
        startTask = nil
        readTask?.cancel()
        readTask = nil
        if let outputBatcher {
            Task { await outputBatcher.cancel() }
        }
        outputBatcher = nil
        if let terminalSession {
            Task { await terminalSession.close() }
        }
        terminalSession = nil
    }

    nonisolated private static func presentation(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private enum MobileTerminalInputError: LocalizedError {
    case agentUnavailable

    var errorDescription: String? {
        String(localized: "This terminal is not attached to an agent.")
    }
}

private enum MobileAgentDisplayMode: String, Equatable {
    case conversation
    case terminal
}

struct MobileTerminalScreen: View {
    @StateObject private var session: MobileAttachSession
    @StateObject private var conversationStore: ConversationReaderStore
    @State private var displayMode: MobileAgentDisplayMode
    @State private var composerText = ""
    @State private var keyboardShown = false
    @State private var showFileImporter = false
    @State private var isStagingAttachment = false
    @State private var isSendingPrompt = false
    @State private var attachmentError: String?
    @State private var inputError: String?
    @State private var terminalControlsHeight: CGFloat = 0
    private let title: String

    init(transport: MobileTransport, target: TerminalAttachTarget, paneID: String, title: String) {
        let session = MobileAttachSession(
            transport: transport,
            target: target,
            paneID: paneID
        )
        _session = StateObject(wrappedValue: session)
        _conversationStore = StateObject(
            wrappedValue: ConversationReaderStore(
                provider: HerdrPaneTranscriptProvider(
                    transport: transport,
                    paneID: paneID
                )
            )
        )
        _displayMode = State(
            initialValue: session.agentPaneID == nil ? .terminal : .conversation
        )
        self.title = title
    }

    var body: some View {
        ZStack {
            terminalBackground.ignoresSafeArea()
            primarySurface
            if displayMode == .terminal,
               case .ended(let reason) = session.status
            {
                endedOverlay(reason)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(terminalBackground, for: .navigationBar)
        .toolbar { displayModeToolbar }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false,
            onCompletion: handleAttachmentSelection
        )
        .alert(
            String(localized: "Could Not Attach File"),
            isPresented: Binding(
                get: { attachmentError != nil },
                set: { if !$0 { attachmentError = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(attachmentError ?? "")
        }
        .alert(
            String(localized: "Could Not Send Input"),
            isPresented: Binding(
                get: { inputError != nil },
                set: { if !$0 { inputError = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(inputError ?? "")
        }
        .onChange(of: displayMode) { _, newValue in
            keyboardShown = false
            switch newValue {
            case .conversation:
                session.stop()
            case .terminal:
                conversationStore.stop()
            }
        }
        .onDisappear {
            conversationStore.stop()
            session.stop()
        }
    }

    @ViewBuilder
    private var primarySurface: some View {
        if displayMode == .conversation, session.agentPaneID != nil {
            VStack(spacing: 0) {
                ConversationReaderView(store: conversationStore)
                    .environment(\.colorScheme, .dark)
                controls
            }
        } else {
            terminalSurface
        }
    }

    private var terminalSurface: some View {
        ZStack(alignment: .bottomTrailing) {
            MobileTerminalHost(
                session: session,
                keyboardShown: $keyboardShown,
                bottomContentInset: terminalControlsHeight
            )
            .ignoresSafeArea(.keyboard, edges: .bottom)

            if !session.isAtLatestOutput {
                terminalLatestButton
                    .padding(.trailing, 14)
                    .padding(.bottom, terminalControlsHeight + 14)
                    .transition(.scale.combined(with: .opacity))
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                controls
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: MobileTerminalControlsHeightKey.self,
                                value: geometry.size.height
                            )
                        }
                    )
            }
        }
        .onPreferenceChange(MobileTerminalControlsHeightKey.self) { height in
            terminalControlsHeight = height
        }
        .animation(.easeOut(duration: 0.16), value: session.isAtLatestOutput)
    }

    @ToolbarContentBuilder
    private var displayModeToolbar: some ToolbarContent {
        if session.agentPaneID != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        displayMode = .conversation
                    } label: {
                        Label(
                            String(localized: "Conversation"),
                            systemImage: displayMode == .conversation
                                ? "checkmark.bubble.fill"
                                : "bubble.left.and.text.bubble.right"
                        )
                    }
                    Button {
                        displayMode = .terminal
                    } label: {
                        Label(
                            String(localized: "Terminal"),
                            systemImage: displayMode == .terminal
                                ? "checkmark.square.fill"
                                : "terminal"
                        )
                    }
                } label: {
                    Image(
                        systemName: displayMode == .conversation
                            ? "bubble.left.and.text.bubble.right"
                            : "terminal"
                    )
                }
                .accessibilityLabel(String(localized: "Choose conversation or terminal view"))
            }
        }
    }

    private var terminalLatestButton: some View {
        Button { session.scrollToLatest() } label: {
            Image(systemName: "arrow.down")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Scroll to latest output"))
    }

    private var terminalBackground: SwiftUI.Color {
        SwiftUI.Color(red: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if displayMode == .terminal {
                keyBar
            }
            if session.agentPaneID != nil {
                composer
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.black.opacity(0.35))
    }

    private var keyBar: some View {
        HStack(spacing: 8) {
            KeyChip("esc") { sendKeys(["esc"]) }
            KeyChip("tab") { sendKeys(["tab"]) }
            KeyChip("↑") { sendKeys(["up"]) }
            KeyChip("↓") { sendKeys(["down"]) }
            KeyChip("⏎") { sendKeys(["enter"]) }
            KeyChip("^C") { sendKeys(["ctrl+c"]) }
            Spacer()
            sessionControl
        }
    }

    @ViewBuilder
    private var sessionControl: some View {
        if session.isControlling {
            Button {
                keyboardShown = false
                session.observe()
            } label: {
                Image(systemName: "eye")
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 34, height: 30)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
            .accessibilityLabel(String(localized: "Release Control"))

            Button {
                keyboardShown.toggle()
            } label: {
                Image(systemName: keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 34, height: 30)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
        } else {
            controlMenu
                .disabled(session.status != .running)
        }
    }

    private var controlMenu: some View {
        Menu {
            Button(String(localized: "Request Control")) {
                keyboardShown = false
                session.requestControl(takeover: false)
            }
            Button(String(localized: "Take Over"), role: .destructive) {
                keyboardShown = false
                session.requestControl(takeover: true)
            }
        } label: {
            Label(String(localized: "Control"), systemImage: "keyboard")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Button {
                showFileImporter = true
            } label: {
                Group {
                    if isStagingAttachment {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "paperclip")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }
            .disabled(isStagingAttachment)
            .accessibilityLabel(String(localized: "Attach File"))

            TextField(
                String(localized: "Message the agent…"),
                text: $composerText,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
            .tint(.white)
            .onSubmit(sendPrompt)

            Button(action: sendPrompt) {
                Group {
                    if isSendingPrompt {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(
                                composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? SwiftUI.Color.white.opacity(0.25) : SwiftUI.Color.accentColor
                            )
                    }
                }
                .frame(width: 28, height: 28)
            }
            .disabled(
                isSendingPrompt
                    || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    private func sendPrompt() {
        let originalText = composerText
        let text = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSendingPrompt else { return }
        isSendingPrompt = true
        conversationStore.resumeFollowing()

        let ticket: TerminalInputQueue.SemanticTicket
        do {
            ticket = try session.prompt(text)
        } catch {
            isSendingPrompt = false
            inputError = presentableInputError(error)
            return
        }

        Task { @MainActor in
            defer { isSendingPrompt = false }
            do {
                try await ticket.value()
                if composerText.hasPrefix(originalText) {
                    composerText.removeFirst(originalText.count)
                }
            } catch {
                inputError = presentableInputError(error)
            }
        }
    }

    private func sendKeys(_ keys: [String]) {
        let ticket = session.sendKeys(keys)
        Task { @MainActor in
            do {
                try await ticket.value()
            } catch {
                inputError = presentableInputError(error)
            }
        }
    }

    private func presentableInputError(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func handleAttachmentSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            attachmentError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            isStagingAttachment = true
            Task { @MainActor in
                defer { isStagingAttachment = false }
                do {
                    let attachment = try await MobileAttachmentLoader.load(from: url)
                    let path = try await session.stageAttachment(attachment)
                    appendAttachmentPath(path)
                } catch {
                    attachmentError =
                        (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    private func appendAttachmentPath(_ path: String) {
        let value = ShellQuoting.quoted(path)
        if composerText.isEmpty {
            composerText = value
        } else {
            let separator = composerText.last?.isWhitespace == true ? "" : " "
            composerText += separator + value
        }
    }

    private func endedOverlay(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Text(reason)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(String(localized: "Observe")) {
                    keyboardShown = false
                    session.observe()
                }
                .buttonStyle(.borderedProminent)
                controlMenu
            }
        }
        .padding(24)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        .padding(20)
    }
}

/// UIKit host for SwiftTerm's iOS TerminalView, wired to the attach session.
private struct MobileTerminalHost: UIViewRepresentable {
    let session: MobileAttachSession
    @Binding var keyboardShown: Bool
    let bottomContentInset: CGFloat

    func makeUIView(context: Context) -> TerminalView {
        var options = TerminalOptions.default
        options.scrollback = 10_000

        let view = TerminalView(
            frame: .zero,
            font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            options: options
        )
        view.terminalDelegate = context.coordinator
        view.backgroundColor = UIColor(
            red: 0x10 / 255,
            green: 0x10 / 255,
            blue: 0x12 / 255,
            alpha: 1
        )
        view.nativeBackgroundColor = view.backgroundColor ?? .black
        view.nativeForegroundColor = UIColor(
            red: 0xD6 / 255,
            green: 0xD6 / 255,
            blue: 0xD6 / 255,
            alpha: 1
        )
        view.allowMouseReporting = false
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = true
        view.showsHorizontalScrollIndicator = false
        view.indicatorStyle = .white
        view.isDirectionalLockEnabled = true
        view.keyboardDismissMode = .interactive
        view.scrollsToTop = true
        try? view.setUseMetal(true)

        session.attachTerminalView(view)
        let terminal = view.getTerminal()
        session.start(columns: terminal.cols, rows: terminal.rows)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        let inset = max(0, bottomContentInset)
        if abs(uiView.contentInset.bottom - inset) > 0.5 {
            let shouldRemainAtLatest = session.isAtLatestOutput
            uiView.contentInset.bottom = inset
            uiView.verticalScrollIndicatorInsets.bottom = inset
            if shouldRemainAtLatest {
                Task { @MainActor in
                    await Task.yield()
                    session.scrollToLatest()
                }
            }
        }

        if keyboardShown, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !keyboardShown, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.session.detachTerminalView(uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: MobileAttachSession
        init(session: MobileAttachSession) { self.session = session }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in self.session.resize(columns: newCols, rows: newRows) }
        }
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor in self.session.send(bytes[...]) }
        }
        nonisolated func scrolled(source: TerminalView, position: Double) {
            Task { @MainActor in self.session.terminalDidScroll(to: position) }
        }
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), url.scheme == "http" || url.scheme == "https" else { return }
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        nonisolated func bell(source: TerminalView) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                Task { @MainActor in UIPasteboard.general.string = text }
            }
        }
        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

private struct MobileTerminalControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct KeyChip: View {
    let label: String
    let action: () -> Void

    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 34)
                .frame(height: 30)
                .padding(.horizontal, 4)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
