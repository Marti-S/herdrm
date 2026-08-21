import AppKit
import HerdrKit
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

enum TerminalDefaults {
    static let fontNameKey = "terminal.fontName"   // "" = system monospaced
    static let fontSizeKey = "terminal.fontSize"
    static let thinStrokesKey = "terminal.thinStrokes"
    static let fontWeightKey = "terminal.fontWeight"
    static let lineSpacingKey = "terminal.lineSpacing"
    static let defaultFontSize: Double = 12.5
    /// `NSFont.Weight` rawValue; 0 is `.regular`. Only the system monospaced font
    /// has selectable weights — named families ship fixed faces and ignore this.
    static let defaultFontWeight: Double = 0
    static let defaultLineSpacing: Double = 1.0
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

    static func font(name: String, size: Double, weight: Double = defaultFontWeight) -> NSFont {
        if !name.isEmpty, let custom = NSFont(name: name, size: size) {
            return custom
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: NSFont.Weight(weight))
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

private struct ClipboardFile: Sendable {
    let localURL: URL
    let removeAfterUpload: Bool
}

private struct PendingAttachmentPaste: Sendable {
    let files: [ClipboardFile]
    let pathSyntax: AgentAttachmentPathSyntax
}

private enum ClipboardFileError: LocalizedError {
    case unsupportedItem
    case imageEncodingFailed
    case transferUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedItem: return "Remote paste supports regular files, not folders or special files."
        case .imageEncodingFailed: return "The clipboard image could not be encoded as PNG."
        case .transferUnavailable: return "The remote file transfer service is unavailable."
        }
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

    var attachmentCapabilities: AgentAttachmentCapabilities?
    var attachmentDeviceKind: Device.Kind = .local
    var attachmentService: HerdrService?
    var onAttachmentError: ((String) -> Void)?
    var onAttachmentUploadingChanged: ((Bool) -> Void)?
    private var pendingUploads: [PendingAttachmentPaste] = []
    private var uploadTask: Task<Void, Never>?

    deinit {
        uploadTask?.cancel()
    }

    override func paste(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        if let fileURLs = Self.fileURLs(in: pasteboard), !fileURLs.isEmpty {
            let action = AgentAttachmentDeliveryPolicy.action(
                capabilities: attachmentCapabilities,
                deviceKind: attachmentDeviceKind,
                source: .files(allImages: fileURLs.allSatisfy(Self.isImageFile))
            )
            handleFilePaste(action: action, fileURLs: fileURLs, sender: sender)
            return
        }

        guard Self.containsImageData(in: pasteboard) else {
            super.paste(sender)
            return
        }

        let action = AgentAttachmentDeliveryPolicy.action(
            capabilities: attachmentCapabilities,
            deviceKind: attachmentDeviceKind,
            source: .imageData
        )
        switch action {
        case .unsupported:
            super.paste(sender)
        case .nativeClipboard:
            forwardNativeClipboardPaste()
        case .devicePaths(let pathSyntax):
            do {
                guard let files = try Self.clipboardFiles(in: pasteboard) else {
                    super.paste(sender)
                    return
                }
                enqueuePathPaste(files, pathSyntax: pathSyntax)
            } catch {
                reportAttachmentError(error)
            }
        }
    }

    private func handleFilePaste(
        action: AgentAttachmentDeliveryAction,
        fileURLs: [URL],
        sender: Any
    ) {
        switch action {
        case .unsupported:
            super.paste(sender)
        case .nativeClipboard:
            forwardNativeClipboardPaste()
        case .devicePaths(let pathSyntax):
            if case .local = attachmentDeviceKind {
                sendPastedText(fileURLs.map { pathSyntax.format($0.path) }.joined(separator: " "))
                return
            }
            do {
                let files = try Self.clipboardFiles(from: fileURLs)
                enqueuePathPaste(files, pathSyntax: pathSyntax)
            } catch {
                reportAttachmentError(error)
            }
        }
    }

    private func forwardNativeClipboardPaste() {
        guard let controlV = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: "\u{16}",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ) else {
            let bytes: [UInt8] = [0x16]
            send(source: self, data: bytes[...])
            return
        }
        super.keyDown(with: controlV)
    }

    private func enqueuePathPaste(
        _ files: [ClipboardFile],
        pathSyntax: AgentAttachmentPathSyntax
    ) {
        guard let attachmentService else {
            discardTemporaries(in: files)
            reportAttachmentError(ClipboardFileError.transferUnavailable)
            return
        }
        pendingUploads.append(PendingAttachmentPaste(files: files, pathSyntax: pathSyntax))
        guard uploadTask == nil else { return }
        onAttachmentUploadingChanged?(true)
        uploadTask = Task { [weak self] in
            await self?.drainPathPastes(using: attachmentService)
        }
    }

    /// Materializes one paste at a time so paths reach the agent in paste order.
    @MainActor
    private func drainPathPastes(using service: HerdrService) async {
        while !pendingUploads.isEmpty {
            let paste = pendingUploads.removeFirst()
            let files = paste.files
            defer { discardTemporaries(in: files) }
            do {
                var devicePaths: [String] = []
                for file in files {
                    try Task.checkCancellation()
                    devicePaths.append(try await service.stageAttachment(from: file.localURL))
                }
                try Task.checkCancellation()
                sendPastedText(devicePaths.map(paste.pathSyntax.format).joined(separator: " "))
            } catch is CancellationError {
                break
            } catch {
                reportAttachmentError(error)
            }
        }
        pendingUploads.forEach { discardTemporaries(in: $0.files) }
        pendingUploads.removeAll()
        uploadTask = nil
        onAttachmentUploadingChanged?(false)
    }

    private func discardTemporaries(in files: [ClipboardFile]) {
        for file in files where file.removeAfterUpload {
            try? FileManager.default.removeItem(at: file.localURL)
        }
    }

    private func sendPastedText(_ text: String) {
        if terminal.bracketedPasteMode {
            let start = Array("\u{1B}[200~".utf8)
            send(source: self, data: start[...])
        }
        let bytes = Array(text.utf8)
        send(source: self, data: bytes[...])
        if terminal.bracketedPasteMode {
            let end = Array("\u{1B}[201~".utf8)
            send(source: self, data: end[...])
        }
    }

    private func reportAttachmentError(_ error: Error) {
        onAttachmentError?(error.localizedDescription)
    }

    private static func clipboardFiles(in pasteboard: NSPasteboard) throws -> [ClipboardFile]? {
        if let fileURLs = fileURLs(in: pasteboard), !fileURLs.isEmpty {
            return try clipboardFiles(from: fileURLs)
        }

        guard !hasText(in: pasteboard),
              let image = pasteboard.readObjects(
                  forClasses: [NSImage.self],
                  options: nil
              )?.first as? NSImage
        else {
            return nil
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw ClipboardFileError.imageEncodingFailed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-clipboard", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let localURL = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).png")
        try png.write(to: localURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: localURL.path
        )
        return [ClipboardFile(localURL: localURL, removeAfterUpload: true)]
    }

    private static func clipboardFiles(from fileURLs: [URL]) throws -> [ClipboardFile] {
        try fileURLs.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw ClipboardFileError.unsupportedItem
            }
            return ClipboardFile(localURL: url, removeAfterUpload: false)
        }
    }

    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    private static func containsImageData(in pasteboard: NSPasteboard) -> Bool {
        !hasText(in: pasteboard)
            && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let contentType = values.contentType
        else { return false }
        return contentType.conforms(to: .image)
    }

    /// Keynote, Excel and Preview attach a TIFF snapshot to copied text, so a
    /// pasteboard only counts as an image when it carries no text at all.
    private static func hasText(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSString.self], options: nil)
    }
}

/// Embeds a SwiftTerm terminal running `herdr agent attach` (directly or over ssh).
struct AttachTerminalView: NSViewRepresentable {
    let device: Device
    let paneID: String
    /// The device's herdr server version, so attach picks a matching CLI binary.
    var serverVersion: String?
    /// nil when the server or active manifest does not advertise attachment support.
    let attachmentCapabilities: AgentAttachmentCapabilities?
    var fontName: String = ""
    var fontSize: Double = TerminalDefaults.defaultFontSize
    /// macOS font smoothing dilates glyph stems, which reads as fake bold at
    /// terminal sizes. Off is SwiftTerm's `fontSmoothing = false` — iTerm2's
    /// "Thin strokes".
    var thinStrokes: Bool = true
    var fontWeight: Double = TerminalDefaults.defaultFontWeight
    var lineSpacing: Double = TerminalDefaults.defaultLineSpacing
    /// From SwiftUI's environment so theme switches re-render immediately.
    var dark: Bool = false
    /// When false, mouse drags always select text locally even if the TUI
    /// requested mouse reporting (Shift+drag bypasses it either way).
    var mouseReporting: Bool = true
    var onAttachmentError: (String) -> Void = { _ in }
    var onAttachmentUploadingChanged: (Bool) -> Void = { _ in }
    /// Called on the main queue when the attach process exits: the pane was taken
    /// over by another client, the SSH connection dropped, or herdr went away. A
    /// dead session otherwise keeps its last frame and silently eats every
    /// keystroke, which reads as a freeze.
    var onExit: ((Int32?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LineBreakTerminalView(frame: .zero)
        configurePasteHandling(view)
        view.processDelegate = context.coordinator
        context.coordinator.onExit = onExit
        configureAppearance(view)

        let service = HerdrService(device: device)
        view.attachmentService = service
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
        // SwiftUI throws this view away and builds a new one whenever the selected
        // agent changes (the `.id("attach-…")` in ContentView), and a fresh NSView is
        // never first responder — so keystrokes went nowhere until the user clicked.
        // The hop to the next runloop pass is required: while `makeNSView` runs the
        // view has no `window` yet.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        if let view = nsView as? LineBreakTerminalView {
            configurePasteHandling(view)
        }
        context.coordinator.onExit = onExit
        configureAppearance(nsView)
    }

    /// Re-applied on update because capabilities can arrive after the terminal
    /// view is created, without changing its identity.
    private func configurePasteHandling(_ view: LineBreakTerminalView) {
        view.attachmentCapabilities = attachmentCapabilities
        view.attachmentDeviceKind = device.kind
        view.onAttachmentError = onAttachmentError
        view.onAttachmentUploadingChanged = onAttachmentUploadingChanged
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        // A view being torn down must not report its own terminate() as an exit.
        coordinator.onExit = nil
        nsView.terminate()
    }

    private func configureAppearance(_ view: LocalProcessTerminalView) {
        let font = TerminalDefaults.font(name: fontName, size: fontSize, weight: fontWeight)
        if view.font != font {
            view.font = font
        }
        view.allowMouseReporting = mouseReporting
        // Compared against the inverted value on purpose: thinStrokes on means
        // smoothing off. The setter only stores the flag, so repaint by hand.
        if view.fontSmoothing == thinStrokes {
            view.fontSmoothing = !thinStrokes
            view.needsDisplay = true
        }
        // This setter calls resetFont(), which recomputes metrics and resizes the
        // terminal, so it is only assigned when it actually changes.
        if view.lineSpacing != CGFloat(lineSpacing) {
            view.lineSpacing = CGFloat(lineSpacing)
        }
        // Everything below is theme-only and returns early; keep font work above it.
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
        var onExit: ((Int32?) -> Void)?

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
            let callback = onExit
            onExit = nil  // report once
            DispatchQueue.main.async { callback?(exitCode) }
        }
    }
}
