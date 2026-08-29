import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let language = "appLanguage"
        static let appearance = "appAppearance"
#if os(macOS)
        static let launchAtLogin = "launchAtLogin"
#endif
    }

    private let defaults: UserDefaults
#if os(macOS)
    private var reconcilingLaunchAtLogin = false
#endif

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

#if os(macOS)
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
#endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.language = defaults.string(forKey: Key.language)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        self.appearance = defaults.string(forKey: Key.appearance)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
#if os(macOS)
        self.launchAtLogin = LaunchAtLogin.isEnabled
#endif
    }

#if os(macOS)
    func refreshLaunchAtLogin() {
        let actualValue = LaunchAtLogin.isEnabled
        guard launchAtLogin != actualValue else { return }

        reconcilingLaunchAtLogin = true
        launchAtLogin = actualValue
        reconcilingLaunchAtLogin = false
    }
#endif
}
