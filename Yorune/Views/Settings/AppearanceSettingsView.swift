import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        PreferencesForm {
            PreferencesRow(label: "Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(LocalizedStringKey(appearance.title)).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}
