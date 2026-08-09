import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject var settings: AppSettings

    private static let acknowledgments: [(name: String, url: URL)] = [
        (
            "Amperfy",
            URL(string: "https://github.com/BLeeEZ/amperfy")!
        ),
        (
            "MacAppSettingsUI",
            URL(string: "https://github.com/usagimaru/MacAppSettingsUI")!
        ),
        (
            "Kaset",
            URL(string: "https://github.com/sozercan/kaset")!
        )
    ]

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Yorune"
    }

    private var versionString: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        PreferencesForm {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appName)
                        .font(.title2.weight(.semibold))
                    Text(
                        "\(String(localized: "Version", locale: settings.language.locale)) \(versionString)"
                    )
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.bottom, 8)

            PreferencesDivider()

            PreferencesRow(label: "Project", alignment: .top) {
                Text("A focused macOS music player for Navidrome")
                    .fixedSize(horizontal: false, vertical: true)
            }

            PreferencesDivider()

            PreferencesRow(label: "Acknowledgments", alignment: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.acknowledgments, id: \.name) { item in
                        Button(item.name) {
                            NSWorkspace.shared.open(item.url)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }
}
