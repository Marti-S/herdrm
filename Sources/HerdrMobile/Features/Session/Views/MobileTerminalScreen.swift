import GameController
import GhosttyTerminal
import HerdrKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers


private enum MobileAgentDisplayMode: String, Equatable {
    case conversation
    case terminal
}

struct MobileTerminalScreen: View {
    @StateObject private var session: MobileAttachSession
    @StateObject private var conversationStore: ConversationReaderViewModel
    @State private var displayMode: MobileAgentDisplayMode
    @State private var composerText = ""
    @State private var keyboardShown = false
    @State private var showFileImporter = false
    @State private var isStagingAttachment = false
    @State private var isSendingPrompt = false
    @State private var attachmentError: String?
    @State private var inputError: String?
    private let title: String

    init(
        transport: MobileTransport,
        target: TerminalAttachTarget,
        paneID: String,
        conversationStore: ConversationReaderViewModel? = nil,
        title: String
    ) {
        let session = MobileAttachSession(
            transport: transport,
            target: target,
            paneID: paneID
        )
        _session = StateObject(wrappedValue: session)
        _conversationStore = StateObject(
            wrappedValue: conversationStore ?? ConversationReaderViewModel(
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
            // The conversation store follows its own view's task lifecycle;
            // only the terminal session needs an explicit stop here.
            if newValue == .conversation {
                session.stop()
            }
        }
        .onDisappear {
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
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                MobileTerminalHost(
                    session: session,
                    keyboardShown: $keyboardShown
                )

                if !session.isAtLatestOutput {
                    terminalLatestButton
                        .padding(.trailing, 14)
                        .padding(.bottom, 14)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            // Ghostty's grid is its view bounds, and a UIView-backed terminal
            // has no content inset to hold output clear of an overlay, so the
            // controls are laid out beside the surface instead of over it.
            controls
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

/// Display-first: a tap on the terminal is a click for the TUI, never a
/// keyboard pop — the toolbar button owns the software keyboard. With a
/// hardware keyboard attached (iPad), the tap still claims first responder
/// so keystrokes land; iOS then shows only the accessory bar.
private final class MobileGhosttyTerminalView: UITerminalView {
    override func toggleSoftwareKeyboard() {
        if GCKeyboard.coalesced != nil {
            _ = becomeFirstResponder()
        }
    }
}

/// UIKit host for Ghostty's UITerminalView on the session's in-memory
/// backend, wired to the attach session.
private struct MobileTerminalHost: UIViewRepresentable {
    let session: MobileAttachSession
    @Binding var keyboardShown: Bool

    func makeUIView(context: Context) -> MobileGhosttyTerminalView {
        let view = MobileGhosttyTerminalView(frame: .zero)
        view.controller = MobileGhosttyRuntime.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session.terminal))
        view.delegate = context.coordinator
        context.coordinator.observeKeyboard(for: view)
        // Scrollback control (jump to latest, restore after an observer
        // reopen) drives the surface through this view.
        session.terminalView = view
        session.start()
        return view
    }

    func updateUIView(_ uiView: MobileGhosttyTerminalView, context _: Context) {
        if keyboardShown {
            uiView.acquireProgrammaticFocus()
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, keyboardShown: $keyboardShown)
    }

    /// Carries the surface's host-side callbacks: scrollbar geometry for the
    /// jump-to-latest affordance and link opens, and keeps the keyboard
    /// binding truthful when the keyboard comes or goes outside the toolbar
    /// button (interactive dismiss, hardware attach).
    @MainActor
    final class Coordinator: NSObject, TerminalSurfaceScrollbarDelegate, TerminalSurfaceOpenURLDelegate {
        let session: MobileAttachSession
        var keyboardShown: Binding<Bool>
        weak var view: MobileGhosttyTerminalView?

        init(session: MobileAttachSession, keyboardShown: Binding<Bool>) {
            self.session = session
            self.keyboardShown = keyboardShown
        }

        func observeKeyboard(for view: MobileGhosttyTerminalView) {
            self.view = view
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardDidShow),
                name: UIResponder.keyboardDidShowNotification, object: nil
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardDidHide),
                name: UIResponder.keyboardDidHideNotification, object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
            session.terminalDidUpdateScrollbar(scrollbar)
        }

        func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
            guard let parsed = URL(string: url),
                  parsed.scheme == "http" || parsed.scheme == "https"
            else { return }
            UIApplication.shared.open(parsed)
        }

        @objc private func keyboardDidShow(_: Notification) {
            guard view?.isFirstResponder == true, !keyboardShown.wrappedValue else { return }
            keyboardShown.wrappedValue = true
        }

        @objc private func keyboardDidHide(_: Notification) {
            guard keyboardShown.wrappedValue else { return }
            keyboardShown.wrappedValue = false
        }
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
