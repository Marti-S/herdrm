import AppKit
import Darwin
import HerdrKit
import Sparkle
import SwiftUI
import UserNotifications

struct TerminalSettingsView: View {
    @AppStorage(TerminalDefaults.fontNameKey) private var fontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var fontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var thinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var fontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var lineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage("terminal.mouseReporting") private var mouseReporting = true

    @State private var importMessage: String?
    @State private var importSucceeded = false

    private let families = TerminalDefaults.monospacedFamilies()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Picker("Font", selection: $fontName) {
                    Text("System Mono (SF Mono)").tag("")
                    Divider()
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                HStack {
                    Slider(value: $fontSize, in: 9...22, step: 0.5) {
                        Text("Size")
                    }
                    Text(String(format: "%.1f pt", fontSize))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                    Stepper("", value: $fontSize, in: 9...22, step: 0.5)
                        .labelsHidden()
                }

                Picker("Weight", selection: $fontWeight) {
                    Text(String(localized: "font.weight.light", defaultValue: "Light"))
                        .tag(Double(NSFont.Weight.light.rawValue))
                    Text(String(localized: "font.weight.regular", defaultValue: "Regular"))
                        .tag(TerminalDefaults.defaultFontWeight)
                    Text(String(localized: "font.weight.medium", defaultValue: "Medium"))
                        .tag(Double(NSFont.Weight.medium.rawValue))
                }
                .pickerStyle(.segmented)
                .disabled(!fontName.isEmpty)
                .help("Only the system monospaced font has selectable weights.")

                HStack {
                    Slider(value: $lineSpacing, in: 1.0...1.4, step: 0.05) {
                        Text("Line spacing")
                    }
                    Text(String(format: "%.0f%%", lineSpacing * 100))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                Toggle(isOn: $thinStrokes) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Thin strokes")
                        Text("Turns off macOS font smoothing, which thickens glyph stems and makes agent output — Claude Code's bold text especially — look heavy and smudged.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $mouseReporting) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mouse reporting")
                        Text("Forwards clicks and drags to TUI apps that ask for them. Turn off to always select text with the mouse — Shift-drag selects either way.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Button("Reset to Defaults") {
                        fontName = ""
                        fontSize = TerminalDefaults.defaultFontSize
                        fontWeight = TerminalDefaults.defaultFontWeight
                        lineSpacing = TerminalDefaults.defaultLineSpacing
                        thinStrokes = true
                        mouseReporting = true
                        importMessage = nil
                    }
                    Button("Import from Ghostty…") { importFromGhostty() }
                        .help("Reads font-family and font-size from ~/.config/ghostty/config. A one-time copy — herdrm's settings stay in charge afterward.")
                }

                if let importMessage {
                    Text(importMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(importSucceeded ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Outside the Form: its two-column layout has no label for these
            // rows and would indent them by the whole label column.
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("❯ herdr agent attach w1:p1 — 中文 ABC 0123")
                    .font(Font(TerminalDefaults.font(name: fontName, size: fontSize, weight: fontWeight)))
                    .lineLimit(1)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.terminalBackground, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(20)
    }

    /// One-time import of the terminal font from `~/.config/ghostty/config`, so a
    /// Ghostty user isn't jarred by a different face (#73). Only the family and
    /// size are copied; herdrm's settings own everything from then on.
    private func importFromGhostty() {
        guard let config = GhosttyConfigImporter.load() else {
            importSucceeded = false
            importMessage = String(
                localized: "ghostty.import.none",
                defaultValue: "No Ghostty config found at ~/.config/ghostty/config."
            )
            return
        }
        var applied: [String] = []
        var skipped: [String] = []

        if let family = config.fontFamily {
            let normalized = family.lowercased().replacingOccurrences(of: " ", with: "")
            if normalized == "sfmono" || normalized == "sfmono-regular" {
                // macOS doesn't expose SF Mono as a pickable family; it is
                // herdrm's built-in default (the empty selection).
                fontName = ""
                applied.append("font System Mono (SF Mono)")
            } else if let resolved = TerminalDefaults.resolveFamily(family) {
                fontName = resolved
                applied.append("font \(resolved)")
            } else {
                skipped.append("font “\(family)” isn't installed")
            }
        }
        if let size = config.fontSize {
            let clamped = min(max(size, 9), 22)
            fontSize = clamped
            applied.append(String(format: "size %.1f pt", clamped))
        }

        if applied.isEmpty && skipped.isEmpty {
            importSucceeded = false
            importMessage = String(
                localized: "ghostty.import.empty",
                defaultValue: "Ghostty config has no font settings to import."
            )
        } else if applied.isEmpty {
            importSucceeded = false
            importMessage = "Couldn't import: " + skipped.joined(separator: "; ") + "."
        } else {
            importSucceeded = true
            var message = "Imported " + applied.joined(separator: ", ")
            if !skipped.isEmpty { message += " (skipped: " + skipped.joined(separator: "; ") + ")" }
            importMessage = message + "."
        }
    }
}
