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
        window.setContentSize(NSSize(width: 640, height: 560))
        window.minSize = NSSize(width: 560, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct FleetBridgePairingView: View {
    let model: AppModel

    @AppStorage(FleetBridgeHostConfiguration.enabledKey) private var enabled = true
    @AppStorage(FleetBridgeHostConfiguration.bindAllInterfacesKey) private var bindAllInterfaces = false
    @AppStorage(FleetBridgeHostConfiguration.portKey) private var storedPort = Int(FleetBridgeProtocol.defaultPort)

    @State private var pairingJSON = ""
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var showRotateConfirmation = false

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
        .frame(minWidth: 560, minHeight: 500)
        .onAppear(perform: reload)
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
            Text(String(localized: "The QR code contains the same pairing JSON. Copy and paste is supported in the current iOS build."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 210)
        }
    }

    private var configuration: some View {
        Form {
            Toggle(String(localized: "Enable mobile bridge"), isOn: $enabled)

            Toggle(isOn: $bindAllInterfaces) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Listen beyond loopback"))
                    Text(String(localized: "Required for direct access through the Mac's Tailscale IP. Leave off when using a raw Tailscale TCP forward."))
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

            Text(bindAllInterfaces
                ? String(localized: "Listening on port \(port) on available interfaces after restart.")
                : String(localized: "Listening on 127.0.0.1:\(port) after restart."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
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

    private func restartBridge() {
        errorMessage = nil
        FleetBridgeServer.shared.stop()
        FleetBridgeServer.shared.start(model: model)
        reload()
    }

    private func reload() {
        copied = false
        do {
            if !FileManager.default.fileExists(
                atPath: FleetBridgeCredentialStore.pairingInfoURL.path
            ) {
                try FleetBridgeCredentialStore.writePairingInfo(
                    configuration: .load(),
                    serverName: Host.current().localizedName
                        ?? ProcessInfo.processInfo.hostName
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
