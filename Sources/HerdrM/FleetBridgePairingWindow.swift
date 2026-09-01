import AppKit
import CoreImage.CIFilterBuiltins
import HerdrKit
import SwiftUI

@MainActor
final class FleetBridgePairingWindowController: NSObject, NSWindowDelegate {
    static let shared = FleetBridgePairingWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        let root = FleetBridgePairingView(model: model)
        if let window {
            window.contentViewController = NSHostingController(rootView: root)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = String(localized: "Mobile Pairing")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 640))
        window.minSize = NSSize(width: 560, height: 580)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private struct FleetBridgePairingView: View {
    let model: AppModel

    @ObservedObject private var bridgeServer = FleetBridgeServer.shared
    @AppStorage(FleetBridgeHostConfiguration.enabledKey) private var enabled = true
    @AppStorage(FleetBridgeHostConfiguration.bindAllInterfacesKey) private var bindAllInterfaces = false
    @AppStorage(FleetBridgeHostConfiguration.portKey) private var storedPort = Int(FleetBridgeProtocol.defaultPort)

    @State private var pairingJSON = ""
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var showRotateConfirmation = false
    @State private var launchAtLogin = FleetBridgeBackgroundLaunch.isRequested
    @State private var backgroundLaunchStatus = FleetBridgeBackgroundLaunch.status

    private var port: UInt16 {
        UInt16(exactly: storedPort) ?? FleetBridgeProtocol.defaultPort
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            HStack(alignment: .top, spacing: 22) {
                qrCard
                configuration
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(String(localized: "Pairing JSON"))
                        .font(.headline)
                    Spacer()
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pairingJSON, forType: .string)
                        copied = true
                    }
                    .disabled(pairingJSON.isEmpty)

                    Button(String(localized: "Reveal File")) {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            FleetBridgeCredentialStore.pairingInfoURL
                        ])
                    }
                    .disabled(!FileManager.default.fileExists(
                        atPath: FleetBridgeCredentialStore.pairingInfoURL.path
                    ))
                }

                ScrollView {
                    Text(pairingJSON.isEmpty ? String(localized: "Pairing data unavailable") : pairingJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 122)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 580)
        .onAppear(perform: reload)
        .onChange(of: bridgeServer.currentNetworkIdentity) { _, _ in
            reload()
        }
        .confirmationDialog(
            String(localized: "Rotate the pairing token?"),
            isPresented: $showRotateConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Rotate Token"), role: .destructive, action: rotateToken)
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Existing iPhone and iPad pairings will stop working until they import the new pairing data."))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(localized: "Pair iPhone or iPad"))
                .font(.title2.weight(.semibold))
            Text(String(localized: "The mobile app receives this Mac's complete HerdrM fleet. Remote SSH credentials never leave the Mac."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var qrCard: some View {
        VStack(spacing: 10) {
            if let image = Self.qrImage(pairingJSON) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 190, height: 190)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
            } else {
                ContentUnavailableView(
                    String(localized: "No Pairing Code"),
                    systemImage: "qrcode"
                )
                .frame(width: 210, height: 210)
            }
            Text(String(localized: "Scan this code from Add Connection → Mac Bridge on iPhone or iPad, or paste the same pairing JSON."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 210)
        }
    }

    private var configuration: some View {
        Form {
            Toggle(String(localized: "Enable mobile bridge"), isOn: $enabled)

            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: updateLaunchAtLogin
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Keep bridge available in background"))
                    Text(String(localized: "Launches HerdrM at login without opening a window. Closing the last window leaves a menu-bar bridge running."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(backgroundLaunchStatus == .unavailable)

            if backgroundLaunchStatus == .requiresApproval {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "macOS requires approval in Login Items before background launch can run."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(String(localized: "Open Login Items Settings")) {
                            FleetBridgeBackgroundLaunch.openSystemSettings()
                        }
                        Button(String(localized: "Check Again"), action: refreshBackgroundLaunchState)
                    }
                }
            } else if backgroundLaunchStatus == .unavailable {
                Text(String(localized: "Background launch is unavailable for this build location or signature."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $bindAllInterfaces) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Listen on all interfaces"))
                    Text(String(localized: "Also exposes the bridge on Wi-Fi and Ethernet. Leave off to use an exact Tailscale address with loopback fallback."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField(
                String(localized: "Port"),
                value: $storedPort,
                format: .number.grouping(.never)
            )

            HStack {
                Button(String(localized: "Apply and Restart Bridge"), action: applyConfiguration)
                    .buttonStyle(.borderedProminent)
                Button(String(localized: "Rotate Token"), role: .destructive) {
                    showRotateConfirmation = true
                }
            }

            Label(networkStatusText, systemImage: networkStatusIcon)
                .font(.caption)
                .foregroundStyle(networkStatusColor)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
    }

    private var networkStatusText: String {
        guard enabled else { return String(localized: "The mobile bridge is disabled.") }
        let identity = bridgeServer.currentNetworkIdentity
        switch identity.scope {
        case .tailscale:
            return String(localized: "Tailscale only: \(identity.pairingHost):\(port)")
        case .loopback:
            return String(localized: "Tailscale is unavailable; listening on 127.0.0.1:\(port) only.")
        case .allInterfaces:
            return String(localized: "Listening on all interfaces at port \(port), including the local network.")
        }
    }

    private var networkStatusIcon: String {
        switch bridgeServer.currentNetworkIdentity.scope {
        case .tailscale: return "checkmark.shield"
        case .loopback: return "desktopcomputer"
        case .allInterfaces: return "exclamationmark.triangle"
        }
    }

    private var networkStatusColor: Color {
        switch bridgeServer.currentNetworkIdentity.scope {
        case .tailscale, .loopback: return .secondary
        case .allInterfaces: return .orange
        }
    }

    private func applyConfiguration() {
        storedPort = Int(port)
        restartBridge()
    }

    private func rotateToken() {
        do {
            _ = try FleetBridgeCredentialStore.rotateToken()
            restartBridge()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateLaunchAtLogin(_ requested: Bool) {
        errorMessage = nil
        do {
            try FleetBridgeBackgroundLaunch.setEnabled(requested)
        } catch {
            refreshBackgroundLaunchState()
            if backgroundLaunchStatus != .requiresApproval {
                errorMessage = error.localizedDescription
            }
            return
        }
        refreshBackgroundLaunchState()
    }

    private func refreshBackgroundLaunchState() {
        backgroundLaunchStatus = FleetBridgeBackgroundLaunch.status
        launchAtLogin = FleetBridgeBackgroundLaunch.isRequested
    }

    private func restartBridge() {
        errorMessage = nil
        bridgeServer.stop()
        bridgeServer.start(model: model)
        reload()
    }

    private func reload() {
        copied = false
        refreshBackgroundLaunchState()
        do {
            if !FileManager.default.fileExists(
                atPath: FleetBridgeCredentialStore.pairingInfoURL.path
            ) {
                try FleetBridgeCredentialStore.writePairingInfo(
                    configuration: .load(),
                    serverName: Host.current().localizedName
                        ?? ProcessInfo.processInfo.hostName,
                    networkIdentity: bridgeServer.currentNetworkIdentity
                )
            }
            let data = try Data(contentsOf: FleetBridgeCredentialStore.pairingInfoURL)
            pairingJSON = String(data: data, encoding: .utf8) ?? ""
            errorMessage = nil
        } catch {
            pairingJSON = ""
            errorMessage = error.localizedDescription
        }
    }

    private static func qrImage(_ payload: String) -> NSImage? {
        guard !payload.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
