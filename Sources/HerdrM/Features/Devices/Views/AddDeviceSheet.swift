import AppKit
import HerdrKit
import SwiftUI

struct AddDeviceSheet: View {
    enum Transport: String, CaseIterable {
        case ssh
        case tailcat
    }

    @ObservedObject var model: FleetStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""
    @State private var transport: Transport = .ssh
    @State private var token = ""

    private var canAdd: Bool {
        switch transport {
        case .ssh: return !target.trimmingCharacters(in: .whitespaces).isEmpty
        case .tailcat: return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "desktopcomputer",
                title: String(localized: "Add Device"),
                subtitle: transport == .ssh
                    ? String(localized: "Uses OpenSSH config, agent, Tailscale SSH, or password")
                    : String(localized: "WireGuard tunnel to a herdr behind NAT — no VPN, no account")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $transport) {
                    Text(String(localized: "SSH")).tag(Transport.ssh)
                    Text(String(localized: "Tailcat")).tag(Transport.tailcat)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer().frame(height: 4)
                SheetSectionLabel("NAME")
                TextField("mac-studio", text: $name)
                    .textFieldStyle(.roundedBorder)
                Spacer().frame(height: 8)
                if transport == .ssh {
                    SheetSectionLabel("SSH TARGET")
                    TextField("vincent@10.10.10.87", text: $target)
                        .textFieldStyle(.roundedBorder)
                    Text("user@host, a ~/.ssh/config alias, or user@host:port for a custom port.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    SheetSectionLabel("TAILCAT TOKEN")
                    TextField("tcpGFwWCD…", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Text("On the remote Mac: `herdr plugin install lbr77/herdr-plugin-tailcat`, then `herdr plugin action invoke herdr.tailcat.token` and paste the token here. The WireGuard tunnel is built in — no external tool. The token is stored in the Keychain. Standalone shells and the Files workspace need SSH.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Device") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    switch transport {
                    case .ssh:
                        let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                        model.addDevice(
                            name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                            sshTarget: trimmedTarget
                        )
                    case .tailcat:
                        model.addTailcatDevice(
                            name: trimmedName.isEmpty ? String(localized: "Tailcat Device") : trimmedName,
                            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
    }
}
