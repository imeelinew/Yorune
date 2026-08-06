import Foundation

struct ServerConfiguration: Sendable {
    let serverURL: String
    let username: String
    let password: String

    var normalized: ServerConfiguration? {
        let serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: serverURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              !username.isEmpty,
              !password.isEmpty else {
            return nil
        }

        return ServerConfiguration(
            serverURL: serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            username: username,
            password: password
        )
    }
}
