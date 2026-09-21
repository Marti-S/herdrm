import AppKit
import Darwin
import HerdrKit
import Sparkle
import SwiftUI
import UserNotifications

struct AgentsSettingsView: View {
    var model: FleetStore
    @State private var drafts: [String: String] = AgentBinaryOverrides.load()

    /// Kinds the picker knows how to start. The lookup command is `kind`,
    /// except Cursor which installs as `cursor-agent`.
    private static let kinds: [(kind: String, label: String, hint: String)] = [
        ("claude", "Claude", "claude"),
        ("codex", "Codex", "codex"),
        ("cursor", "Cursor", "cursor-agent"),
        ("gemini", "Gemini", "gemini"),
        ("grok", "Grok", "grok"),
        ("kimi", "Kimi", "kimi"),
        ("opencode", "OpenCode", "opencode"),
        ("pi", "Pi", "pi"),
        ("atomic", "Atomic", "atomic"),
        ("omp", "Oh My Pi", "omp"),
        ("copilot", "Copilot", "copilot"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.kinds, id: \.kind) { row in
                    TextField(row.label, text: binding(row.kind), prompt: Text("Automatic"))
                        .font(.system(size: 12).monospaced())
                        .help(String(localized: "Command or path for \(row.hint). Leave empty to detect."))
                }
            } footer: {
                Text("Finder-launched apps don’t inherit your terminal PATH. herdrm captures it once from a login + interactive shell, then looks up these names. A path here is an escape hatch when detection picks the wrong binary.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onAppear { drafts = AgentBinaryOverrides.load() }
        .onChange(of: drafts) { _, _ in commit() }
        .onDisappear(perform: commit)
        .onSubmit(commit)
    }

    private func commit() {
        AgentBinaryOverrides.save(drafts)
        model.reloadAgentCatalog(deviceID: Device.local.id)
    }

    private func binding(_ kind: String) -> Binding<String> {
        Binding(
            get: { drafts[kind] ?? "" },
            set: { drafts[kind] = $0 }
        )
    }
}
