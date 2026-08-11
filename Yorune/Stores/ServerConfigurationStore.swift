import Combine
import Foundation

@MainActor
final class ServerConfigurationStore: ObservableObject {
    private enum Keys {
        static let serverURL = "navidrome.serverURL"
        static let username = "navidrome.username"
        static let keychainService = "com.eli.Yorune.navidrome"
        static let keychainAccount = "default"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    var configuration: ServerConfiguration? {
        guard let serverURL = defaults.string(forKey: Keys.serverURL),
              let username = defaults.string(forKey: Keys.username),
              let password = try? keychain.read(
                service: Keys.keychainService,
                account: Keys.keychainAccount
              ) else {
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

        try keychain.save(
            configuration.password,
            service: Keys.keychainService,
            account: Keys.keychainAccount
        )
        defaults.set(configuration.serverURL, forKey: Keys.serverURL)
        defaults.set(configuration.username, forKey: Keys.username)
        objectWillChange.send()
    }
}

enum ServerConfigurationError: Error {
    case invalid
}
