import HerdrKit
import SwiftTerm
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One live transport-neutral terminal session, pumped into a SwiftTerm view.
///
/// The session outlives view updates and ends when its transport reports
/// orderly closure, ownership loss, or a network failure. Direct SSH uses
/// Herdr's structured observe/control stream; bridge mode can later provide the
/// same frames without changing this presentation layer.
///
/// Mobile terminals are display-first (Heeler's ADR 0013 insight): the live
/// pane renders, but typing goes through the composer (`agent.prompt`) and a
/// key bar (`pane.send_input` keys), which herdr encodes properly server-side.
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

    let transport: MobileTransport
    let target: TerminalAttachTarget
    let paneID: String

    private enum InputOperation {
        case terminal(Data, generation: UInt64)
        case resize(TerminalSize, generation: UInt64)
        case rpc(method: String, params: JSONValue, generation: UInt64)
    }

    private var terminalSession: (any TerminalSession)?
    private var outputBatcher: MobileTerminalOutputBatcher?
    private var startTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputOperations: [InputOperation] = []
    private var inputTaskGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var lastSize = TerminalSize(columns: 80, rows: 24)
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
        let generation = lifecycleGeneration
        let outputBatcher = MobileTerminalOutputBatcher { [weak self] data in
            guard let self, self.lifecycleGeneration == generation else { return }
            self.feed(data)
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

    private func restart(mode: TerminalSessionMode) {
        let size = lastSize
        stop()
        start(columns: size.columns, rows: size.rows, mode: mode)
    }

    private func pump(
        _ terminalSession: any TerminalSession,
        outputBatcher: MobileTerminalOutputBatcher,
        generation: UInt64
    ) {
        let complete: @MainActor @Sendable (String) -> Void = { [weak self] endingReason in
            guard let self, self.lifecycleGeneration == generation else { return }
            self.outputBatcher = nil
            if case .running = self.status {
                self.status = .ended(endingReason)
            }
        }
        readTask = Task.detached(priority: .userInitiated) {
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
            await complete(endingReason)
        }
    }

    private func feed(_ data: Data) {
        terminalView?.feed(byteArray: ArraySlice([UInt8](data)))
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard terminalSession != nil, mode.allowsInput else { return }
        enqueueInput(.terminal(Data(bytes), generation: lifecycleGeneration))
    }

    /// Sends named keys through herdr's RPC — proper terminal encoding without
    /// this client knowing the pane's keyboard protocol state. These semantic
    /// controls remain available while the terminal itself is read-only.
    func sendKeys(_ keys: [String]) {
        enqueueInput(.rpc(
            method: "pane.send_input",
            params: .object([
                "pane_id": .string(paneID),
                "keys": .array(keys.map { .string($0) }),
            ]),
            generation: lifecycleGeneration
        ))
    }

    /// Sends a prompt to the agent; herdr delivers and submits it. This remains
    /// available to an observer because it is a semantic agent operation, not
    /// raw ownership of the terminal byte stream.
    func prompt(_ text: String) {
        guard let agentPaneID else { return }
        enqueueInput(.rpc(
            method: "agent.prompt",
            params: .object([
                "target": .string(agentPaneID),
                "text": .string(text),
            ]),
            generation: lifecycleGeneration
        ))
    }

    private func enqueueInput(_ operation: InputOperation) {
        if case .terminal(let incoming, let generation) = operation,
           case .terminal(let existing, let existingGeneration)? = inputOperations.last,
           generation == existingGeneration {
            var combined = existing
            combined.append(incoming)
            inputOperations[inputOperations.count - 1] = .terminal(
                combined,
                generation: generation
            )
        } else {
            inputOperations.append(operation)
        }
        startInputPumpIfNeeded()
    }

    private func startInputPumpIfNeeded() {
        guard inputTask == nil else { return }
        inputTaskGeneration &+= 1
        let taskGeneration = inputTaskGeneration
        inputTask = Task { [weak self] in
            guard let self else { return }
            await self.drainInput(taskGeneration: taskGeneration)
        }
    }

    private func drainInput(taskGeneration: UInt64) async {
        while !Task.isCancelled, !inputOperations.isEmpty {
            let operation = inputOperations.removeFirst()
            switch operation {
            case .terminal(let data, let generation):
                guard generation == lifecycleGeneration,
                      let terminalSession,
                      mode.allowsInput
                else { continue }
                try? await terminalSession.send(data)

            case .resize(let size, let generation):
                guard generation == lifecycleGeneration,
                      let terminalSession,
                      mode.allowsResize
                else { continue }
                try? await terminalSession.resize(size)

            case .rpc(let method, let params, let generation):
                guard generation == lifecycleGeneration else { continue }
                _ = try? await transport.request(method: method, params: params)
            }
        }
        if inputTaskGeneration == taskGeneration {
            inputTask = nil
            if !inputOperations.isEmpty {
                startInputPumpIfNeeded()
            }
        }
    }

    func stageAttachment(_ attachment: MobileAttachmentPayload) async throws -> String {
        try await transport.stageAttachment(attachment)
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        let size = TerminalSize(columns: columns, rows: rows)
        guard size != lastSize else { return }
        lastSize = size

        guard terminalSession != nil else { return }
        if mode.allowsResize {
            enqueueInput(.resize(size, generation: lifecycleGeneration))
        } else {
            // Observe mode negotiates its grid when the stream opens. Coalesce
            // layout churn before reopening so rotation does not create a
            // connection storm.
            resizeTask?.cancel()
            resizeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.restart(mode: .observe)
            }
        }
    }

    func stop() {
        lifecycleGeneration &+= 1
        resizeTask?.cancel()
        resizeTask = nil
        startTask?.cancel()
        startTask = nil
        readTask?.cancel()
        readTask = nil
        inputTaskGeneration &+= 1
        inputTask?.cancel()
        inputTask = nil
        inputOperations.removeAll(keepingCapacity: true)
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
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

struct MobileTerminalScreen: View {
    @StateObject private var session: MobileAttachSession
    @State private var composerText = ""
    @State private var keyboardShown = false
    @State private var showFileImporter = false
    @State private var isStagingAttachment = false
    @State private var attachmentError: String?
    private let title: String

    init(transport: MobileTransport, target: TerminalAttachTarget, paneID: String, title: String) {
        _session = StateObject(
            wrappedValue: MobileAttachSession(transport: transport, target: target, paneID: paneID)
        )
        self.title = title
    }

    var body: some View {
        ZStack {
            terminalBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                MobileTerminalHost(session: session, keyboardShown: $keyboardShown)
                controls
            }
            if case .ended(let reason) = session.status {
                endedOverlay(reason)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(terminalBackground, for: .navigationBar)
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
        .onDisappear { session.stop() }
    }

    private var terminalBackground: SwiftUI.Color {
        SwiftUI.Color(red: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            keyBar
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
            KeyChip("esc") { session.sendKeys(["esc"]) }
            KeyChip("tab") { session.sendKeys(["tab"]) }
            KeyChip("↑") { session.sendKeys(["up"]) }
            KeyChip("↓") { session.sendKeys(["down"]) }
            KeyChip("⏎") { session.sendKeys(["enter"]) }
            KeyChip("^C") { session.sendKeys(["ctrl+c"]) }
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
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? SwiftUI.Color.white.opacity(0.25) : SwiftUI.Color.accentColor
                    )
            }
            .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sendPrompt() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.prompt(text)
        composerText = ""
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

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.backgroundColor = UIColor(red: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1)
        view.nativeBackgroundColor = view.backgroundColor ?? .black
        view.nativeForegroundColor = UIColor(red: 0xD6 / 255, green: 0xD6 / 255, blue: 0xD6 / 255, alpha: 1)
        session.terminalView = view
        let terminal = view.getTerminal()
        session.start(columns: terminal.cols, rows: terminal.rows)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        if keyboardShown, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !keyboardShown, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
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
        nonisolated func scrolled(source: TerminalView, position: Double) {}
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
