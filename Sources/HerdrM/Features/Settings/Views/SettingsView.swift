import AppKit
import Darwin
import HerdrKit
import Sparkle
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @ObservedObject var model: FleetStore

    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            TerminalSettingsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            AgentsSettingsView(model: model)
                .tabItem { Label("Agents", systemImage: "sparkles") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            FleetBridgePairingView(model: model)
                .tabItem { Label("Mobile", systemImage: "iphone") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640)
    }
}
