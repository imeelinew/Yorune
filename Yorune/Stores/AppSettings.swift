import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let language = "appLanguage"
        static let appearance = "appAppearance"
        static let launchAtLogin = "launchAtLogin"
    }

    private let defaults: UserDefaults
    private var reconcilingLaunchAtLogin = false

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
        }
    }

    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            appearance.apply()
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard !reconcilingLaunchAtLogin else { return }

            let actualValue = LaunchAtLogin.set(launchAtLogin)
            defaults.set(actualValue, forKey: Key.launchAtLogin)

            guard actualValue != launchAtLogin else { return }
            reconcilingLaunchAtLogin = true
            launchAtLogin = actualValue
            reconcilingLaunchAtLogin = false
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.language = defaults.string(forKey: Key.language)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        self.appearance = defaults.string(forKey: Key.appearance)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        self.launchAtLogin = LaunchAtLogin.isEnabled
    }

    func refreshLaunchAtLogin() {
        let actualValue = LaunchAtLogin.isEnabled
        guard launchAtLogin != actualValue else { return }

        reconcilingLaunchAtLogin = true
        launchAtLogin = actualValue
        reconcilingLaunchAtLogin = false
    }
}
