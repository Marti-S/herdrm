import HerdrKit
import SwiftTerm
import SwiftUI

/// Renders the persistent Herdr terminal owned by one Space's ⌘D split.
///
/// Unlike the old app-owned login shell, this terminal lives in the Herdr
/// session. It remains alive while another Space is selected, can be reattached
/// after an app restart, and is automatically present in the mobile fleet.
struct SpaceSplitTerminalView: View {
    @ObservedObject var model: AppModel
    let session: AppModel.SpaceSplitSession
    let fontName: String
    let fontSize: Double
    let thinStrokes: Bool
    let fontWeight: Double
    let lineSpacing: Double
    let dark: Bool
    let mouseReporting: Bool
    let onViewReady: (LocalProcessTerminalView) -> Void

    @State private var attachRetry = 0
    @State private var ended = false
    @State private var endedCode: Int32?

    var body: some View {
        Group {
            switch session.terminal {
            case .creating:
                statusView(
                    systemImage: "terminal",
                    title: String(localized: "Creating Sidecar Terminal…"),
                    detail: String(localized: "This persistent terminal will also be available on iPhone and iPad."),
                    showsProgress: true
                )

            case .failed(let message):
                statusView(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "Could Not Create Sidecar"),
                    detail: message,
                    primaryAction: (
                        String(localized: "Retry"),
                        { model.retrySplitTerminal(for: session.space) }
                    ),
                    secondaryAction: (
                        String(localized: "Close Split"),
                        { model.closeSplitSession(for: session.space) }
                    )
                )

            case .ready(_, let terminalID):
                readyTerminal(terminalID: terminalID)
            }
        }
        .background(Theme.terminalBackground)
        .onChange(of: session.terminal) { _, _ in
            ended = false
            endedCode = nil
            attachRetry += 1
        }
    }

    private func readyTerminal(terminalID: String) -> some View {
        Group {
            if let device = model.device(session.space.deviceID) {
                ZStack {
                    AttachTerminalView(
                        device: device,
                        target: .terminal(terminalID: terminalID),
                        serverVersion: model.serverVersion(deviceID: device.id),
                        attachmentCapabilities: nil,
                        fontName: fontName,
                        fontSize: fontSize,
                        thinStrokes: thinStrokes,
                        fontWeight: fontWeight,
                        lineSpacing: lineSpacing,
                        dark: dark,
                        mouseReporting: mouseReporting,
                        onExit: { code in
                            endedCode = code
                            ended = true
                        },
                        onViewReady: onViewReady
                    )
                    .id("space-sidecar-\(session.id.uuidString)-\(terminalID)-\(attachRetry)")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

                    if ended {
                        endedOverlay(deviceName: device.name)
                    }
                }
            } else {
                statusView(
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                    title: String(localized: "Device Unavailable"),
                    detail: String(localized: "The device that owns this Sidecar is no longer configured."),
                    secondaryAction: (
                        String(localized: "Close Split"),
                        { model.closeSplitSession(for: session.space) }
                    )
                )
            }
        }
    }

    private func endedOverlay(deviceName: String) -> some View {
        let dropped = endedCode == 255
        return VStack(spacing: 10) {
            Image(systemName: dropped ? "bolt.horizontal.circle" : "rectangle.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textGhost)
            Text(
                dropped
                    ? String(localized: "Connection to \(deviceName) dropped")
                    : String(localized: "Sidecar terminal session ended")
            )
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            Text(String(localized: "The persistent terminal is still owned by Herdr unless it was closed from another client."))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button(String(localized: "Reconnect")) {
                    ended = false
                    endedCode = nil
                    attachRetry += 1
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)

                Button(String(localized: "Close Sidecar"), role: .destructive) {
                    model.closeSplitSession(for: session.space)
                }
                .controlSize(.small)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground.opacity(0.94))
    }

    private func statusView(
        systemImage: String,
        title: String,
        detail: String,
        showsProgress: Bool = false,
        primaryAction: (String, () -> Void)? = nil,
        secondaryAction: (String, () -> Void)? = nil
    ) -> some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.textGhost)
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if primaryAction != nil || secondaryAction != nil {
                HStack(spacing: 8) {
                    if let primaryAction {
                        Button(primaryAction.0, action: primaryAction.1)
                            .controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                    }
                    if let secondaryAction {
                        Button(secondaryAction.0, role: .destructive, action: secondaryAction.1)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
