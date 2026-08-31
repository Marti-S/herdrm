import HerdrKit
import SwiftTerm
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One live transport-neutral terminal session, pumped into a SwiftTerm view.
///
/// The session outlives view updates and ends when its transport reports
/// orderly closure, ownership loss, or a network failure. Direct SSH uses
/// Herdr's structured observe/control stream; bridge mode provides the same
/// frames without changing this presentation layer.
///
/// Mobile terminals are display-first: the live pane renders, while Agent
/// prompts, logical keys, and capability-aware attachments use semantic Herdr
/// operations. Raw keyboard input still requires an explicit control lease.
@MainActor
final class MobileAttachSession: ObservableObject {
    enum Status: Equatable {
        case connecting
        case running
        case ended(String)
    }

    @Published var status: Status = .connecting
    @Published private(set) var mode: TerminalSessionMode = .observe
    @Published private(set) var attachmentCapabilities: AgentAttachmentCapabilities?
    @Published private(set) var attachmentCapabilitiesLoaded = false

    let transport: MobileTransport
    let target: TerminalAttachTarget
    let paneID: String
    let agentKind: String?

    private var terminalSession: (any TerminalSession)?
    private var startTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var attachmentCapabilityTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var lastSize = TerminalSize(columns: 80, rows: 24)
    weak var terminalView: TerminalView?

    init(
        transport: MobileTransport,
        target: TerminalAttachTarget,
        paneID: String,
        agentKind: String?
    ) {
        self.transport = transport
        self.target = target
        self.paneID = paneID
        self.agentKind = agentKind
    }

    var agentPaneID: String? {
        if case .agent(let paneID) = target { return paneID }
        return nil
    }

    var isControlling: Bool {
        mode.access == .control && status == .running
    }

    var supportsAttachmentUpload: Bool {
        agentPaneID != nil && transport is any MobileAttachmentTransport
    }

    var canAttachFiles: Bool {
        guard supportsAttachmentUpload, let attachmentCapabilities else { return false }
        return attachmentCapabilities.imagePath != nil
            || attachmentCapabilities.filePath != nil
    }

    func start(
        columns: Int,
        rows: Int,
        mode requestedMode: TerminalSessionMode = .observe
    ) {
        loadAttachmentCapabilitiesIfNeeded()
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
                self.pump(terminalSession, generation: generation)
            } catch {
                guard !Task.isCancelled, self.lifecycleGeneration == generation else { return }
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
        generation: UInt64
    ) {
        readTask = Task { [weak self] in
            var endingReason = String(localized: "Session ended")
            do {
                while !Task.isCancelled {
                    guard let frame = try await terminalSession.read() else { break }
                    guard !frame.bytes.isEmpty else { continue }
                    self?.feed(frame.bytes)
                }
            } catch {
                endingReason = Self.presentation(error)
            }

            await terminalSession.close()
            guard
                let self,
                !Task.isCancelled,
                self.lifecycleGeneration == generation
            else { return }
            if case .running = self.status {
                self.status = .ended(endingReason)
            }
        }
    }

    private func feed(_ data: Data) {
        terminalView?.feed(byteArray: ArraySlice([UInt8](data)))
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard let terminalSession, mode.allowsInput else { return }
        let data = Data(bytes)
        Task { try? await terminalSession.send(data) }
    }

    /// Sends named keys through Herdr's RPC. These semantic controls remain
    /// available while the terminal itself is read-only.
    func sendKeys(_ keys: [String]) {
        Task {
            _ = try? await transport.request(
                method: "pane.send_input",
                params: .object([
                    "pane_id": .string(paneID),
                    "keys": .array(keys.map { .string($0) }),
                ])
            )
        }
    }

    /// Sends a prompt to the Agent; this remains available to an observer
    /// because it does not take raw ownership of the terminal byte stream.
    func prompt(_ text: String) {
        guard let agentPaneID else { return }
        Task {
            _ = try? await transport.request(
                method: "agent.prompt",
                params: .object([
                    "target": .string(agentPaneID),
                    "text": .string(text),
                ])
            )
        }
    }

    func attachmentPathSyntax(allImages: Bool) throws -> AgentAttachmentPathSyntax {
        guard supportsAttachmentUpload else { throw AttachmentUploadError.unavailable }
        guard let capabilities = attachmentCapabilities else {
            throw AttachmentUploadError.unsupportedAgent
        }
        if allImages, let imagePath = capabilities.imagePath {
            return imagePath
        }
        guard let filePath = capabilities.filePath else {
            throw AttachmentUploadError.unsupportedAgent
        }
        return filePath
    }

    func stageAttachment(fileName: String, data: Data) async throws -> String {
        guard let uploader = transport as? any MobileAttachmentTransport else {
            throw AttachmentUploadError.unavailable
        }
        return try await uploader.stageAttachment(fileName: fileName, data: data)
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        let size = TerminalSize(columns: columns, rows: rows)
        guard size != lastSize else { return }
        lastSize = size

        guard let terminalSession else { return }
        if mode.allowsResize {
            Task { try? await terminalSession.resize(size) }
        } else {
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
        if let terminalSession {
            Task { await terminalSession.close() }
        }
        terminalSession = nil
    }

    private func loadAttachmentCapabilitiesIfNeeded() {
        guard supportsAttachmentUpload,
              !attachmentCapabilitiesLoaded,
              attachmentCapabilityTask == nil,
              let agentKind
        else {
            if !supportsAttachmentUpload || agentKind == nil {
                attachmentCapabilitiesLoaded = true
            }
            return
        }

        attachmentCapabilityTask = Task { [weak self] in
            guard let self else { return }
            defer { self.attachmentCapabilityTask = nil }
            let registry: AgentAttachmentCapabilityRegistry
            do {
                struct Envelope: Decodable { let manifests: [AgentManifestInfo] }
                let envelope = try await transport.request(
                    method: "server.agent_manifests",
                    params: .object([:]),
                    as: Envelope.self
                )
                registry = AgentAttachmentCapabilityRegistry(manifests: envelope.manifests)
            } catch {
                // Built-in fallbacks preserve attachment support for known
                // Agents when an older Herdr server cannot report manifests.
                registry = AgentAttachmentCapabilityRegistry(manifests: [])
            }
            guard !Task.isCancelled else { return }
            self.attachmentCapabilities = registry.capabilities(for: agentKind)
            self.attachmentCapabilitiesLoaded = true
        }
    }

    private static func presentation(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

struct MobileTerminalScreen: View {
    @StateObject private var session: MobileAttachSession
    @State private var composerText = ""
    @State private var keyboardShown = false
    @State private var showingAttachmentPicker = false
    @State private var isUploadingAttachments = false
    @State private var attachmentError: String?
    private let title: String

    init(
        transport: MobileTransport,
        target: TerminalAttachTarget,
        paneID: String,
        title: String,
        agentKind: String? = nil
    ) {
        _session = StateObject(
            wrappedValue: MobileAttachSession(
                transport: transport,
                target: target,
                paneID: paneID,
                agentKind: agentKind
            )
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
            isPresented: $showingAttachmentPicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true,
            onCompletion: handleAttachmentSelection
        )
        .alert(
            String(localized: "Attachment Failed"),
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
            attachmentControl

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
            .disabled(
                isUploadingAttachments
                    || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    @ViewBuilder
    private var attachmentControl: some View {
        if session.supportsAttachmentUpload {
            if isUploadingAttachments || !session.attachmentCapabilitiesLoaded {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
            } else if session.canAttachFiles {
                Button {
                    showingAttachmentPicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
                .disabled(isUploadingAttachments)
                .accessibilityLabel(String(localized: "Attach Files"))
            }
        }
    }

    private func sendPrompt() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isUploadingAttachments else { return }
        session.prompt(text)
        composerText = ""
    }

    private func handleAttachmentSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure(let error):
            attachmentError = error.localizedDescription
        case .success(let urls):
            Task { await stageAttachments(from: urls) }
        }
    }

    @MainActor
    private func stageAttachments(from urls: [URL]) async {
        guard !isUploadingAttachments else { return }
        isUploadingAttachments = true
        defer { isUploadingAttachments = false }
        do {
            let attachments = try await MobilePickedAttachment.load(urls: urls)
            let syntax = try session.attachmentPathSyntax(
                allImages: attachments.allSatisfy(\.isImage)
            )
            var paths: [String] = []
            paths.reserveCapacity(attachments.count)
            for attachment in attachments {
                let path = try await session.stageAttachment(
                    fileName: attachment.fileName,
                    data: attachment.data
                )
                paths.append(path)
            }
            let insertion = paths.map(syntax.format).joined(separator: " ")
            guard !insertion.isEmpty else { return }
            if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                composerText = insertion
            } else {
                composerText += " " + insertion
            }
        } catch {
            attachmentError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
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
