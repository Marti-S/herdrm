import AppKit
import HerdrKit
import SwiftUI

struct RootView: View {
    // Owned by AppDelegate so it outlives the window — see AppDelegate in HerdrMApp.swift.
    @ObservedObject var model: FleetStore
    // Deliberately not persisted: the app always launches with the sidebar visible.
    @State private var sidebarCollapsed = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                SidebarView(model: model, collapsed: $sidebarCollapsed)
                    .frame(width: sidebarCollapsed ? 0 : 260, alignment: .trailing)
                    .clipped()
                Rectangle()
                    .fill(Theme.sidebarBorder)
                    .frame(width: sidebarCollapsed ? 0 : 1)
                    .ignoresSafeArea()
                DetailView(model: model, sidebarCollapsed: $sidebarCollapsed)
            }
            .animation(.easeInOut(duration: 0.2), value: sidebarCollapsed)

            // In-window device panel; NSPopover throws in ViewBridge on macOS 26+ betas.
            if model.showDevicePanel {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { model.showDevicePanel = false }
                DevicePopover(model: model, isPresented: $model.showDevicePanel)
                    .padding(.leading, 10)
                    .padding(.bottom, 46)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
                    .background(
                        Button("") { model.showDevicePanel = false }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    )
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: model.showDevicePanel)
        .background(
            Button("") { sidebarCollapsed.toggle() }
                .keyboardShortcut("b", modifiers: .command)
                .hidden()
        )
        .background(
            Button("") { model.showSearch = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        )
        .focusedSceneValue(\.appModel, model)
        .focusedSceneValue(\.splitAxis, model.shellSplitAxis)
        .sheet(isPresented: $model.showSearch) { SearchSheet(model: model) }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 620)
        .onAppear { model.start() }
        .sheet(isPresented: $model.showAddDevice) { AddDeviceSheet(model: model) }
        .sheet(isPresented: $model.showNewAgent) { NewAgentSheet(model: model) }
        .sheet(isPresented: $model.showNewTerminal) { NewTerminalSheet(model: model) }
        .sheet(isPresented: $model.showNewSpace) { NewSpaceSheet(model: model) }
        .sheet(item: $model.spaceToRename) { entry in RenameSpaceSheet(model: model, entry: entry) }
        .sheet(item: $model.agentToRename) { entry in RenameAgentSheet(model: model, entry: entry) }
        .sheet(item: $model.terminalToRename) { entry in RenameTerminalSheet(model: model, entry: entry) }
        .sheet(item: $model.deviceToEdit) { device in EditDeviceSheet(model: model, device: device) }
        .sheet(item: $model.sshAuthenticationRequest) { request in
            SSHAuthenticationSheet(model: model, request: request)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            if model.hasReconnectableDevice {
                Button("Reconnect") { model.reconnectFailedDevices() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .alert(
            model.closeRequest?.title ?? "",
            isPresented: Binding(
                get: { model.closeRequest != nil },
                set: { if !$0 { model.closeRequest = nil } }
            )
        ) {
            Button("Close", role: .destructive) {
                model.closeRequest?.perform()
                model.closeRequest = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.closeRequest?.message ?? "")
        }
    }
}

/// Titlebar metrics: 28pt matches the system traffic-light centerline (14pt) exactly.
enum TitlebarMetrics {
    static let height: CGFloat = 28
    static let trafficLightClearance: CGFloat = 78
}

private struct WindowTitlebarInteraction: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        WindowTitlebarInteractionView()
    }

    func updateNSView(_: NSView, context _: Context) {}
}

private final class WindowTitlebarInteractionView: NSView {
    private static let fillRestoreFrames =
        NSMapTable<NSWindow, NSValue>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var rememberFrameWorkItem: DispatchWorkItem?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rememberFrameWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        Self.rememberNonFilledFrame(of: window)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFrameDidChange(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFrameDidChange(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    deinit {
        rememberFrameWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowFrameDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        rememberFrameWorkItem?.cancel()
        let item = DispatchWorkItem { [weak window] in
            guard let window else { return }
            Self.rememberNonFilledFrame(of: window)
        }
        rememberFrameWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        guard !window.styleMask.contains(.fullScreen) else { return }

        let action = UserDefaults.standard
            .string(forKey: "AppleActionOnDoubleClick")?
            .lowercased()
        switch action {
        case "fill":
            Self.toggleFill(window)
        case nil:
            if #available(macOS 15.0, *) {
                Self.toggleFill(window)
            } else {
                Self.fillRestoreFrames.removeObject(forKey: window)
                window.performZoom(nil)
            }
        case "minimize":
            Self.fillRestoreFrames.removeObject(forKey: window)
            window.performMiniaturize(nil)
        case "none":
            break
        default:
            Self.fillRestoreFrames.removeObject(forKey: window)
            window.performZoom(nil)
        }
    }

    private static func toggleFill(_ window: NSWindow) {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return
        }
        if framesApproximatelyEqual(window.frame, visibleFrame) {
            let previous = fillRestoreFrames.object(forKey: window)?.rectValue
                ?? fallbackRestoreFrame(in: visibleFrame)
            fillRestoreFrames.removeObject(forKey: window)
            let restored = constrainedRestoreFrame(previous, for: window)
            window.setFrame(restored, display: true, animate: true)
        } else {
            fillRestoreFrames.setObject(NSValue(rect: window.frame), forKey: window)
            window.setFrame(visibleFrame, display: true, animate: true)
        }
    }

    private static func rememberNonFilledFrame(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame,
              !framesApproximatelyEqual(window.frame, visibleFrame)
        else { return }
        fillRestoreFrames.setObject(NSValue(rect: window.frame), forKey: window)
    }

    private static func fallbackRestoreFrame(in visibleFrame: NSRect) -> NSRect {
        visibleFrame.insetBy(
            dx: visibleFrame.width * 0.1,
            dy: visibleFrame.height * 0.1
        )
    }

    private static func framesApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1
            && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1
            && abs(lhs.height - rhs.height) < 1
    }

    private static func constrainedRestoreFrame(_ frame: NSRect, for window: NSWindow) -> NSRect {
        let intersectingScreen = NSScreen.screens
            .map { screen in
                let intersection = frame.intersection(screen.visibleFrame)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                return (screen, area)
            }
            .max { $0.1 < $1.1 }
        let screen = if let intersectingScreen, intersectingScreen.1 > 0 {
            intersectingScreen.0
        } else {
            window.screen ?? NSScreen.main
        }
        guard let screen else { return frame }
        return window.constrainFrameRect(frame, to: screen)
    }
}

private struct WindowTitlebarInteractionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(WindowTitlebarInteraction())
    }
}

extension View {
    func windowTitlebarInteraction() -> some View {
        modifier(WindowTitlebarInteractionModifier())
    }
}
