import HerdrKit
import SwiftTerm
import SwiftUI
import UIKit

/// One live transport-neutral terminal session, pumped into a SwiftTerm view.
///
/// The session outlives view updates and ends when its transport reports
/// orderly closure, ownership loss, or a network failure. Direct SSH currently
/// adapts a PTY; bridge mode can later supply structured observe/control frames
/// without changing this presentation layer.
///
/// Mobile terminals are display-first (Heeler's ADR 0013 insight): the live
/// pane renders, but typing goes through the composer (`agent.prompt`) and a
/// key bar (`pane.send_input` keys), which herdr encodes properly server-side.
/// A keyboard toggle still allows raw typing for TUI menus that need it.
@MainActor
final class MobileAttachSession: ObservableObject {
    enum Status: Equatable {
        case connecting
        case running
        case ended(String)
    }

    @Published var status: Status = .connecting
    let transport: MobileTransport
    let target: TerminalAttachTarget
    private var terminalSession: (any TerminalSession)?
    private var readTask: Task<Void, Never>?
    weak var terminalView: TerminalView?

    /// The herdr pane behind this attach, for key/prompt RPCs.
    let paneID: String

    init(transport: MobileTransport, target: TerminalAttachTarget, paneID: String) {
        self.transport = transport
        self.target = target
        self.paneID = paneID
    }

    var agentPaneID: String? {
        if case .agent(let paneID) = target { return paneID }
        return nil
    }

    func start(columns: Int, rows: Int) {
        guard terminalSession == nil else { return }
        status = .connecting
        Task {
            do {
                let size = TerminalSize(
                    columns: max(columns, 20),
                    rows: max(rows, 5)
                )
                let terminalSession = try await transport.openTerminalSession(
                    target: target,
                    mode: .control(takeover: true),
                    size: size
                )
                self.terminalSession = terminalSession
                self.status = .running
                self.pump(terminalSession)
            } catch {
                self.status = .ended(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
        }
    }

    private func pump(_ terminalSession: any TerminalSession) {
        readTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let frame = try await terminalSession.read() else { break }
                    guard !frame.bytes.isEmpty else { continue }
                    self?.feed(frame.bytes)
                }
            } catch {}
            guard let self, !Task.isCancelled else { return }
            if case .running = self.status {
                self.status = .ended(String(localized: "Session ended"))
            }
        }
    }

    private func feed(_ data: Data) {
        terminalView?.feed(byteArray: ArraySlice([UInt8](data)))
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard let terminalSession else { return }
        let data = Data(bytes)
        Task { try? await terminalSession.send(data) }
    }

    /// Sends named keys through herdr's RPC — proper terminal encoding without
    /// this client knowing the pane's keyboard protocol state.
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

    /// Sends a prompt to the agent; herdr delivers and submits it.
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

    func resize(columns: Int, rows: Int) {
        guard let terminalSession, columns > 0, rows > 0 else { return }
        let size = TerminalSize(columns: columns, rows: rows)
        Task { try? await terminalSession.resize(size) }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        if let terminalSession {
            Task { await terminalSession.close() }
        }
        terminalSession = nil
    }
}

struct MobileTerminalScreen: View {
    @StateObject private var session: MobileAttachSession
    @State private var composerText = ""
    @State private var keyboardShown = false
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
            Button {
                keyboardShown.toggle()
            } label: {
                Image(systemName: keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 34, height: 30)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
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

    private func endedOverlay(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Text(reason)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
            Button(String(localized: "Reconnect")) {
                session.stop()
                session.start(columns: 80, rows: 24)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
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
