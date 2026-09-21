import AppKit
import Darwin
import HerdrKit
import Sparkle
import SwiftUI
import UserNotifications

struct AppearanceSettingsView: View {
    @AppStorage("app.theme") private var themePreference = "system"
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Picker("Theme", selection: $themePreference) {
                Text(String(localized: "theme.system", defaultValue: "System")).tag("system")
                Text(String(localized: "theme.light", defaultValue: "Light")).tag("light")
                Text(String(localized: "theme.dark", defaultValue: "Dark")).tag("dark")
            }
            .pickerStyle(.segmented)
            Text("The terminal follows the app theme.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Language") {
                HStack(spacing: 8) {
                    Picker("Language", selection: $language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(verbatim: option.displayName).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: language) { _, newValue in
                        AppLanguage.apply(AppLanguage(rawValue: newValue) ?? .system)
                    }
                    if AppLanguage.needsRelaunch(AppLanguage(rawValue: language) ?? .system) {
                        Button("Relaunch") {
                            AppLanguage.relaunch()
                        }
                        .help("Quit and reopen herdrm so the new language takes effect.")
                    }
                }
            }
        }
        .padding(20)
    }
}
