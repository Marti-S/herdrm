import GameController
import GhosttyTerminal
import HerdrKit
import SwiftUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The process-wide Ghostty app object for the phone's terminals: every
/// surface shares one controller, mirroring the Mac app's GhosttyRuntime.
/// The mobile chrome is dark-only, so the theme pins the dark palette to
/// both schemes rather than following the OS appearance.
@MainActor
enum MobileGhosttyRuntime {
    /// The font/cursor settings land as a configuration override (the
    /// controller's hot-apply path), the theme at construction.
    static let controller: TerminalController = {
        let controller = TerminalController(configSource: .none, theme: makeTheme())
        controller.setTerminalConfiguration(makeConfiguration())
        return controller
    }()

    /// Same dark colors as the Mac app (`TerminalDefaults`): #101012 on
    /// #D6D6D6 with the Terminal.app 16-color palette.
    private static let backgroundHex = "#101012"
    private static let foregroundHex = "#D6D6D6"
    private static let palette: [(red: Int, green: Int, blue: Int)] = [
        (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
        (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
        (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35),
        (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235),
    ]

    /// Bundled Nerd Font symbols (MIT, github.com/ryanoasis/nerd-fonts),
    /// registered process-wide at app launch, for the icon glyphs agent
    /// TUIs draw. iOS has no user font cascade for the PUA, so the ranges
    /// are codepoint-mapped like on the Mac.
    private static let symbolFallbackFamily = "Symbols Nerd Font Mono"

    static func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    private static func makeConfiguration() -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontSize(12)
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            // Counter the default config's font-thicken: fake bold at
            // terminal sizes reads as smear on a phone screen.
            builder.withFontThicken(false)
            // Menlo is always present on iOS; SF Mono is not resolvable by
            // family name there.
            builder.withFontFamily("Menlo")
            builder.withCustom("font-codepoint-map", "U+E000-U+F8FF=\(symbolFallbackFamily)")
            builder.withCustom("font-codepoint-map", "U+F0000-U+FFFFD=\(symbolFallbackFamily)")
            builder.withCustom("font-codepoint-map", "U+100000-U+10FFFD=\(symbolFallbackFamily)")
        }
    }

    private static func makeTheme() -> TerminalTheme {
        let dark = TerminalConfiguration { builder in
            builder.withBackground(backgroundHex)
            builder.withForeground(foregroundHex)
            for (index, color) in palette.enumerated() {
                builder.withPalette(index, color: hex(color))
            }
        }
        return TerminalTheme(light: dark, dark: dark)
    }

    private static func hex(_ color: (red: Int, green: Int, blue: Int)) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }
}

/// The Ghostty surface as seen from the session's `@Sendable` callbacks.
/// Both directions hop to the main actor, where the session owns the input
/// queue and the control lease: bytes the surface produces are input (and
/// are dropped unless this client holds control), and grid reports open or
/// resize the transport session.
private final class MobileSurfaceBridge: @unchecked Sendable {
    weak var owner: MobileAttachSession?

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        Task { @MainActor [weak owner] in owner?.send(data) }
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        Task { @MainActor [weak owner] in
            owner?.handleViewportResize(columns: columns, rows: rows)
        }
    }
}

/// One live attach: a transport-neutral terminal session — direct SSH or the
/// Mac bridge, both exposing the same ordered terminal-frame surface —
/// rendered by a host-managed (in-memory) Ghostty surface. The session
/// outlives view updates and ends when its transport reports orderly
/// closure, ownership loss, or a network failure.
///
/// Both directions run through this object: the transport's frames are
/// batched into `terminal.receive`, and everything the surface emits
/// (keystrokes, DA/OSC replies, grid resizes) comes back on the main actor
/// through the input queue.
///
/// Mobile terminals are display-first: the live pane renders, but typing can
/// go through the composer (`agent.prompt`) and key bar (`pane.send_input`),
/// which herdr encodes server-side. Raw keyboard input requires an explicit
/// control lease.
@MainActor
final class MobileAttachSession: ObservableObject {
    enum Status: Equatable {
        case connecting
        case running
        case ended(String)
    }

    @Published var status: Status = .connecting
    @Published private(set) var mode: TerminalSessionMode = .observe
    @Published private(set) var isAtLatestOutput = true

    let transport: MobileTransport
    let target: TerminalAttachTarget

    /// The host-managed Ghostty backend the surface in `MobileTerminalHost`
    /// renders. Created up front so the view can attach before the transport
    /// session exists — output is buffered by the session until then.
    let terminal: InMemoryTerminalSession
    /// Carries the surface's off-main callbacks back to this actor.
    private let surfaceBridge: MobileSurfaceBridge
    /// Last grid the surface reported. A reconnect opens at this size instead
    /// of waiting for a fresh viewport report (an unchanged grid dispatches
    /// no new resize).
    private var lastGrid: (columns: Int, rows: Int)?

    /// The herdr pane behind this attach, for key/prompt RPCs.
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
    private var startTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var lastSize = TerminalSize(columns: 80, rows: 24)
    /// Absolute scrollback row to reveal once output resumes after an
    /// observer reopen.
    private var pendingScrollRestore: UInt64?
    /// The scrollbar geometry Ghostty last reported, in rows.
    private var scrollbar: TerminalScrollbar?
    weak var terminalView: UITerminalView?

    init(transport: MobileTransport, target: TerminalAttachTarget, paneID: String) {
        self.transport = transport
        self.target = target
        self.paneID = paneID
        let bridge = MobileSurfaceBridge()
        surfaceBridge = bridge
        terminal = InMemoryTerminalSession(
            write: { data in bridge.write(data) },
            resize: { viewport in
                bridge.resize(columns: Int(viewport.columns), rows: Int(viewport.rows))
            },
            // Only grid changes reach the remote PTY; pixel-only updates
            // would just re-report the same winsize.
            suppressesPixelOnlyResizes: true
        )
        bridge.owner = self
    }

    var agentPaneID: String? {
        if case .agent(let paneID) = target { return paneID }
        return nil
    }

    var isControlling: Bool {
        mode.access == .control && status == .running
    }

    /// Marks the session ready to attach. The transport session opens on the
    /// surface's first viewport report, at the exact grid, so the remote pane
    /// never has to repaint for a SIGWINCH; a reconnect already knows the
    /// grid and opens immediately.
    func start(mode requestedMode: TerminalSessionMode = .observe) {
        guard terminalSession == nil, startTask == nil else { return }
        mode = requestedMode
        status = .connecting
        if let lastGrid {
            open(columns: lastGrid.columns, rows: lastGrid.rows)
        }
    }

    /// Ghostty reports the grid from its IO thread (hopped to the main actor
    /// by `MobileSurfaceBridge`). The first report opens the session; later
    /// ones resize it.
    func handleViewportResize(columns: Int, rows: Int) {
        lastGrid = (columns, rows)
        guard terminalSession == nil, startTask == nil else {
            resize(columns: columns, rows: rows)
            return
        }
        guard case .connecting = status else { return }
        open(columns: columns, rows: rows)
    }

    /// A remote pane is unusable below a handful of cells, and a transient
    /// layout pass can report one. Open and resize clamp identically so a
    /// clamped grid never reads back as a size change.
    private static func clamped(columns: Int, rows: Int) -> TerminalSize {
        TerminalSize(columns: max(columns, 20), rows: max(rows, 5))
    }

    private func open(columns: Int, rows: Int) {
        let size = Self.clamped(columns: columns, rows: rows)
        let requestedMode = mode
        lastSize = size
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
                // The grid may have moved while the session was opening.
                if let grid = self.lastGrid {
                    self.resize(columns: grid.columns, rows: grid.rows)
                }
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
        let restoreRow = preserveScrollPosition && !isAtLatestOutput
            ? scrollbar?.offset
            : nil
        stop()
        pendingScrollRestore = restoreRow
        start(mode: mode)
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

    /// `SSHStructuredTerminalSession` already consumed the attach bootstrap
    /// marker and the shell chatter ahead of it, so every byte here is pane
    /// output and goes straight to the Ghostty surface.
    private func feed(_ data: Data, generation: UInt64) {
        guard lifecycleGeneration == generation else { return }
        terminal.receive(data)
        firstFrameDidArrive(generation: generation)
    }

    private func firstFrameDidArrive(generation: UInt64) {
        guard lifecycleGeneration == generation,
              let row = pendingScrollRestore
        else { return }
        pendingScrollRestore = nil

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.lifecycleGeneration == generation else { return }
            self.terminalView?.scrollToRow(UInt(row))
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

    /// Raw bytes the surface produced: keystrokes, and Ghostty's own DA/OSC
    /// replies. An observer holds no input lease, so its bytes are dropped
    /// here rather than rejected by the remote.
    func send(_ data: Data) {
        guard terminalSession != nil, mode.allowsInput else { return }
        inputQueue.enqueueTerminal(data, generation: lifecycleGeneration)
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
        let size = Self.clamped(columns: columns, rows: rows)
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
        // and preserve the reader's scrollback row across it.
        guard size.columns != previousSize.columns else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.restart(mode: .observe, preserveScrollPosition: true)
        }
    }

    /// Ghostty's scrollbar geometry, in rows: `offset` rows sit above the
    /// viewport, `len` are visible, out of `total`. This is what the
    /// jump-to-latest affordance reads — `UITerminalView` is a plain
    /// `UIView` with no content offset to measure.
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        self.scrollbar = scrollbar
        isAtLatestOutput = scrollbar.offset + scrollbar.len >= scrollbar.total
    }

    func scrollToLatest() {
        guard let scrollbar, scrollbar.total > 0 else { return }
        terminalView?.scrollToRow(UInt(scrollbar.total - 1))
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


enum MobileTerminalInputError: LocalizedError {
    case agentUnavailable

    var errorDescription: String? {
        String(localized: "This terminal is not attached to an agent.")
    }
}
