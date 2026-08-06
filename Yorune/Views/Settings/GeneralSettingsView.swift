import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        PreferencesForm {
            PreferencesRow(label: "Language") {
                Picker("Application Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.title)).tag(language)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            PreferencesRow(label: "Startup", alignment: .firstTextBaseline) {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.checkbox)
            }
        }
        .onAppear {
            settings.refreshLaunchAtLogin()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            settings.refreshLaunchAtLogin()
        }
    }
}
