import AppKit
import HerdrKit
import SwiftTerm
import SwiftUI

enum TerminalDefaults {
    static let fontNameKey = "terminal.fontName"   // "" = system monospaced
    static let fontSizeKey = "terminal.fontSize"
    static let defaultFontSize: Double = 12.5
    static let darkBackground = NSColor(
        srgbRed: 0x10 / 255,
        green: 0x10 / 255,
        blue: 0x12 / 255,
        alpha: 1
    )
    static let darkForeground = NSColor(
        srgbRed: 0xD6 / 255,
        green: 0xD6 / 255,
        blue: 0xD6 / 255,
        alpha: 1
    )
    static let lightBackground = NSColor.white
    static let lightForeground = NSColor(
        srgbRed: 0x3A / 255,
        green: 0x3A / 255,
        blue: 0x3A / 255,
        alpha: 1
    )
    static let darkPalette = SwiftTerm.Color.terminalAppColors
    /// Per entry, keep whichever of the original and luminance-flipped color reads
    /// better on the light background: the flip rescues colors designed for dark
    /// backgrounds (white, the bright variants), but ANSI red/blue/magenta/black
    /// are already dark and would wash out to pastels.
    static let lightPalette = darkPalette.map { color in
        let original = (
            red: Int(color.red / 257),
            green: Int(color.green / 257),
            blue: Int(color.blue / 257)
        )
        let flipped = LightTerminalANSIAdapter.lightRGB(
            red: original.red,
            green: original.green,
            blue: original.blue
        )
        let originalContrast = LightTerminalANSIAdapter.contrastOnWhite(
            red: original.red, green: original.green, blue: original.blue
        )
        let flippedContrast = LightTerminalANSIAdapter.contrastOnWhite(
            red: flipped.red, green: flipped.green, blue: flipped.blue
        )
        let chosen = originalContrast >= flippedContrast ? original : flipped
        return SwiftTerm.Color(
            red8: UInt16(chosen.red),
            green8: UInt16(chosen.green),
            blue8: UInt16(chosen.blue)
        )
    }

    static func font(name: String, size: Double) -> NSFont {
        if !name.isEmpty, let custom = NSFont(name: name, size: size) {
            return custom
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Fixed-pitch font families available on this Mac, for the settings picker.
    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }
}

/// Sends ESC CR for Shift+Return so agent TUIs insert a line break instead of
/// submitting: legacy terminal encoding sends the same bare `\r` for Enter and
/// Shift+Enter, so the modifier never reaches the TUI. SwiftTerm's `keyDown`
/// and `doCommand` are public, not open, so `interpretKeyEvents` is the only
/// hook a subclass can take — and it only sees Return in legacy mode, leaving
/// this inert when a TUI negotiates the kitty keyboard protocol.
final class LineBreakTerminalView: LocalProcessTerminalView {
    var usesLightColors = false
    var appliedDarkAppearance: Bool?
    private var lightColorAdapter = LightTerminalANSIAdapter()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        guard usesLightColors else {
            super.dataReceived(slice: slice)
            return
        }
        let transformed = lightColorAdapter.transform(slice)
        if !transformed.isEmpty {
            feed(byteArray: transformed[...])
        }
    }

    // Dragging always selects text locally, like a native text view. With mouse
    // reporting on, SwiftTerm forwards every mouse event to the TUI (herdr's
    // attach stream requests the mouse, and via XTSHIFTESCAPE even Shift+drag),
    // leaving no way to select or copy anything. Clicks and the scroll wheel
    // still reach the TUI — only drags (and Shift/double/triple clicks, which
    // only mean selection) are kept local by parking mouse reporting for the
    // duration of the event.
    private func withLocalSelection(_ event: NSEvent, _ forward: (NSEvent) -> Void) {
        let saved = allowMouseReporting
        allowMouseReporting = false
        forward(event)
        allowMouseReporting = saved
    }

    private func isSelectionGesture(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
            || event.clickCount > 1
    }

    override func mouseDown(with event: NSEvent) {
        // A plain click deactivates any selection. SwiftTerm's own branch for
        // that is unreachable while mouse reporting forwards the click, so do
        // it here — then let the click reach the TUI as usual.
        if !isSelectionGesture(event), selection.active {
            selection.selectNone()
            needsDisplay = true
        }
        if isSelectionGesture(event) {
            withLocalSelection(event) { super.mouseDown(with: $0) }
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        withLocalSelection(event) { super.mouseDragged(with: $0) }
    }

    override func mouseUp(with event: NSEvent) {
        if isSelectionGesture(event) {
            withLocalSelection(event) { super.mouseUp(with: $0) }
        } else {
            super.mouseUp(with: event)
        }
    }

    // Right-click context menu. SwiftTerm's link lookup is internal, so link
    // items key off the selected text instead — a double-click selects a whole
    // URL, which pairs naturally with right-click.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if selection.active {
            menu.addItem(makeItem("Copy", #selector(NSText.copy(_:))))
            if let url = Self.firstURL(in: selection.getSelectedText()) {
                menu.addItem(.separator())
                let open = makeItem("Open Link", #selector(openLinkFromMenu(_:)))
                open.representedObject = url
                menu.addItem(open)
                let copyLink = makeItem("Copy Link Address", #selector(copyLinkFromMenu(_:)))
                copyLink.representedObject = url
                menu.addItem(copyLink)
            }
            menu.addItem(.separator())
        }
        menu.addItem(makeItem("Paste", #selector(NSText.paste(_:))))
        menu.addItem(makeItem("Select All", #selector(NSText.selectAll(_:))))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector?.firstMatch(in: text, range: range),
              let url = match.url,
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        if eventArray.count == 1,
           let event = eventArray.first,
           event.type == .keyDown,
           event.keyCode == 36 || event.keyCode == 76,  // Return, keypad Enter
           !hasMarkedText() {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.shift),
               modifiers.isDisjoint(with: [.command, .control, .option]) {
                send(txt: "\u{1b}\r")
                return
            }
        }
        super.interpretKeyEvents(eventArray)
    }
}

/// Embeds a SwiftTerm terminal running `herdr agent attach` (directly or over ssh).
struct AttachTerminalView: NSViewRepresentable {
    let device: Device
    let paneID: String
    /// The device's herdr server version, so attach picks a matching CLI binary.
    var serverVersion: String?
    var fontName: String = ""
    var fontSize: Double = TerminalDefaults.defaultFontSize
    /// From SwiftUI's environment so theme switches re-render immediately.
    var dark: Bool = false
    /// When false, mouse drags always select text locally even if the TUI
    /// requested mouse reporting (Shift+drag bypasses it either way).
    var mouseReporting: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LineBreakTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        configureAppearance(view)

        let service = HerdrService(device: device)
        let command = service.attachCommand(paneID: paneID, serverVersion: serverVersion)
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("LANG=en_US.UTF-8")
        for (key, value) in command.environment {
            environment.removeAll { $0.hasPrefix("\(key)=") }
            environment.append("\(key)=\(value)")
        }
        context.coordinator.authorizationID = command.authorizationID
        context.coordinator.scheduleAuthorizationCleanup()
        view.startProcess(
            executable: command.executable,
            args: command.args,
            environment: environment
        )
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        configureAppearance(nsView)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }

    private func configureAppearance(_ view: LocalProcessTerminalView) {
        let font = TerminalDefaults.font(name: fontName, size: fontSize)
        if view.font != font {
            view.font = font
        }
        view.allowMouseReporting = mouseReporting
        guard let view = view as? LineBreakTerminalView,
              view.appliedDarkAppearance != dark
        else { return }
        view.appliedDarkAppearance = dark
        view.usesLightColors = !dark
        view.nativeBackgroundColor = dark ? TerminalDefaults.darkBackground : TerminalDefaults.lightBackground
        view.nativeForegroundColor = dark ? TerminalDefaults.darkForeground : TerminalDefaults.lightForeground
        view.installColors(dark ? TerminalDefaults.darkPalette : TerminalDefaults.lightPalette)
        view.needsDisplay = true
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var authorizationID: UUID?

        deinit {
            discardAuthorization()
        }

        func scheduleAuthorizationCleanup() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.discardAuthorization()
            }
        }

        private func discardAuthorization() {
            guard let authorizationID else { return }
            try? SSHCredentialStore.removeAuthorization(authorizationID)
            self.authorizationID = nil
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            discardAuthorization()
        }
    }
}
