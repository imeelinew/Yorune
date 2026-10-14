import Combine
import Foundation

@MainActor
final class ServerConfigurationStore: ObservableObject {
    private enum Keys {
        static let serverURL = "navidrome.serverURL"
        static let username = "navidrome.username"
        static let password = "navidrome.password"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var configuration: ServerConfiguration? {
        guard let serverURL = defaults.string(forKey: Keys.serverURL),
              let username = defaults.string(forKey: Keys.username),
              let password = defaults.string(forKey: Keys.password) else {
            return nil
        }

        return ServerConfiguration(
            serverURL: serverURL,
            username: username,
            password: password
        ).normalized
    }

    func save(_ configuration: ServerConfiguration) throws {
        guard let configuration = configuration.normalized else {
            throw ServerConfigurationError.invalid
        }

        defaults.set(configuration.password, forKey: Keys.password)
        defaults.set(configuration.serverURL, forKey: Keys.serverURL)
        defaults.set(configuration.username, forKey: Keys.username)
        objectWillChange.send()
    }
}

enum ServerConfigurationError: Error, LocalizedError {
    case invalid

    var errorDescription: String? {
        String(localized: "The server address or credentials are invalid.")
    }

    var recoverySuggestion: String? {
        String(localized: "Enter a complete address beginning with http:// or https://.")
    }
}
