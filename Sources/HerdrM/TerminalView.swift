import AppKit
import HerdrKit
import SwiftTerm
import SwiftUI

enum TerminalDefaults {
    static let fontNameKey = "terminal.fontName"   // "" = system monospaced
    static let fontSizeKey = "terminal.fontSize"
    static let defaultFontSize: Double = 12.5

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

/// Embeds a SwiftTerm terminal running `herdr agent attach` (directly or over ssh).
struct AttachTerminalView: NSViewRepresentable {
    let device: Device
    let paneID: String
    var fontName: String = ""
    var fontSize: Double = TerminalDefaults.defaultFontSize

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        configureAppearance(view)

        let service = HerdrService(device: device)
        let command = service.attachCommand(paneID: paneID)
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("LANG=en_US.UTF-8")
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

    private func configureAppearance(_ view: LocalProcessTerminalView) {
        let font = TerminalDefaults.font(name: fontName, size: fontSize)
        if view.font != font {
            view.font = font
        }
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark {
            view.nativeBackgroundColor = NSColor(srgbRed: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1)
            view.nativeForegroundColor = NSColor(srgbRed: 0xD6 / 255, green: 0xD6 / 255, blue: 0xD6 / 255, alpha: 1)
        } else {
            view.nativeBackgroundColor = .white
            view.nativeForegroundColor = NSColor(srgbRed: 0x3A / 255, green: 0x3A / 255, blue: 0x3A / 255, alpha: 1)
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}
