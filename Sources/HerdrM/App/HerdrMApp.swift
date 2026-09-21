import AppKit
import Darwin
import HerdrKit
import Sparkle
import SwiftUI
import UserNotifications

/// Holds app termination open long enough to tear the SSH tunnels down: without
/// `.terminateLater` the process dies before the teardown task gets to run, and the
/// `ssh` children survive with PPID 1 along with their sockets.
///
/// The delegate owns the model rather than borrowing it from the window: closing the
/// last window (⌘W) would otherwise drop the only strong reference, and the quit that
/// follows would find nothing left to tear down.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let dependencies = AppDependencies()
    var model: FleetStore { dependencies.fleetStore }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.shutdownAllSessions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct FleetStoreFocusedValueKey: FocusedValueKey {
    typealias Value = FleetStore
}

/// The split axis travels as its own focused value, not read off the model. `Commands`
/// gets the FleetStore by reference and never subscribes to its objectWillChange, so
/// `focusedModel?.shellSplitAxis` was evaluated once and stuck: the menu items stayed
/// disabled with a split open, and a disabled NSMenuItem does not fire its key
/// equivalent. A value type changes identity, which does invalidate the commands body —
/// that is also what lets the shortcuts follow the current axis.
private struct SplitAxisFocusedValueKey: FocusedValueKey {
    typealias Value = SplitAxis
}

extension FocusedValues {
    var appModel: FleetStore? {
        get { self[FleetStoreFocusedValueKey.self] }
        set { self[FleetStoreFocusedValueKey.self] = newValue }
    }

    var splitAxis: SplitAxis? {
        get { self[SplitAxisFocusedValueKey.self] }
        set { self[SplitAxisFocusedValueKey.self] = newValue }
    }
}

@main
struct HerdrMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("app.theme") private var themePreference = "system"
    @FocusedValue(\.appModel) private var focusedModel
    @FocusedValue(\.splitAxis) private var focusedSplitAxis

    private let updaterController: SPUStandardUpdaterController

    init() {
        if ProcessInfo.processInfo.environment[SSHCredentialStore.askPassModeEnvironmentKey] == "1" {
            Self.runSSHAskPass()
        }
        AppLanguage.synchronize()
        SSHCredentialStore.purgeAuthorizations()
        TerminalDefaults.registerBundledFonts()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: appDelegate.model)
                .onAppear { Self.applyTheme(themePreference) }
                .onChange(of: themePreference) { _, newValue in
                    Self.applyTheme(newValue)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // herdrm is a single-window console: a second window would duplicate the
            // whole device tree, so New Window gives up ⌘N to the action that matters.
            CommandGroup(replacing: .newItem) {
                Button("New Agent") { focusedModel?.showNewAgent = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(focusedModel == nil)
                Button("New Terminal") { focusedModel?.showNewTerminal = true }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(focusedModel == nil)
                Button("New Space") { focusedModel?.showNewSpace = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(focusedModel == nil)
            }

            CommandGroup(after: .appInfo) {
                Button("Mobile Pairing…") {
                    FleetBridgePairingWindowController.shared.show(model: appDelegate.model)
                }

                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }

            CommandMenu("Terminal") {
                // Guarded on the active Herdr Space: standalone terminals and Files keep
                // the prior pane selected for fast restoration, but must not mutate a
                // hidden Space split.
                Button("Split Vertically") { focusedModel?.shellSplitAxis = .vertical }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(focusedModel?.attachedSpaceRef == nil)
                Button("Split Horizontally") { focusedModel?.shellSplitAxis = .horizontal }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(focusedModel?.attachedSpaceRef == nil)

                Divider()

                // Eight items with FIXED shortcuts, enabled per axis — deliberately not
                // four items whose shortcut follows the axis. Measured: `.disabled` IS
                // revalidated when the menu opens, but a key equivalent already registered
                // in the NSMenu is NOT reassigned when the commands body re-evaluates, so
                // the arrows stayed frozen on the axis that was current at launch.
                // Labels name the direction so no two rows read the same.
                //
                // Focus is directional and idempotent: the left/top pane is always the
                // agent, the right/bottom one always the shell.
                Button("Focus Left Pane") {
                    if let model = focusedModel { focusSplitSide(.agent, in: model) }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(focusedSplitAxis != .vertical)
                Button("Focus Right Pane") {
                    if let model = focusedModel { focusSplitSide(.shell, in: model) }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(focusedSplitAxis != .vertical)
                Button("Focus Top Pane") {
                    if let model = focusedModel { focusSplitSide(.agent, in: model) }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(focusedSplitAxis != .horizontal)
                Button("Focus Bottom Pane") {
                    if let model = focusedModel { focusSplitSide(.shell, in: model) }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(focusedSplitAxis != .horizontal)

                Divider()

                // Resize moves the divider by 5% relative to the active pane.
                Button("Widen Active Pane") {
                    if let model = focusedModel { resizeSplit(grow: true, in: model) }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(focusedSplitAxis != .vertical)
                Button("Narrow Active Pane") {
                    if let model = focusedModel { resizeSplit(grow: false, in: model) }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(focusedSplitAxis != .vertical)
                Button("Grow Active Pane") {
                    if let model = focusedModel { resizeSplit(grow: true, in: model) }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(focusedSplitAxis != .horizontal)
                Button("Shrink Active Pane") {
                    if let model = focusedModel { resizeSplit(grow: false, in: model) }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(focusedSplitAxis != .horizontal)
            }
            CommandGroup(replacing: .saveItem) {
                // ⌘W closes the most local thing first: the split, then the
                // selected standalone terminal, then the window. Server-owned
                // panes close from their confirmed sidebar action instead.
                Button(closeButtonTitle) {
                    if let model = focusedModel, model.shellSplitAxis != nil {
                        model.shellSplitAxis = nil
                    } else if let model = focusedModel, let shell = model.selectedShell {
                        model.closeShellSession(shell.id)
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }

    private var closeButtonTitle: String {
        if focusedModel?.shellSplitAxis != nil { return String(localized: "Close Split") }
        if focusedModel?.selectedShell != nil { return String(localized: "Close Terminal") }
        return String(localized: "Close")
    }

    static func applyTheme(_ preference: String) {
        switch preference {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - Split commands

    private func focusSplitSide(_ side: SplitSide, in model: FleetStore) {
        guard model.shellSplitAxis != nil else { return }
        let target = (side == .agent) ? model.splitAgentView : model.splitShellView
        guard let target, let window = target.window else { return }
        window.makeFirstResponder(target)
    }

    private func resizeSplit(grow: Bool, in model: FleetStore) {
        guard model.shellSplitAxis != nil else { return }
        let step = 0.05
        let signed = (model.activeSplitSide == .agent) ? step : -step
        let delta = grow ? signed : -signed
        model.splitRatio = min(0.8, max(0.2, model.splitRatio + delta))
    }

    private static func runSSHAskPass() -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let rawID = environment[SSHCredentialStore.authorizationIDEnvironmentKey],
              let authorizationID = UUID(uuidString: rawID),
              let password = try? SSHCredentialStore.consumePassword(authorizationID: authorizationID)
        else {
            Darwin.exit(EXIT_FAILURE)
        }
        FileHandle.standardOutput.write(Data("\(password)\n".utf8))
        Darwin.exit(EXIT_SUCCESS)
    }
}
