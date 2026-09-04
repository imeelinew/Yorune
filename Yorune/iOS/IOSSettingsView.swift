import OSLog
import SwiftUI

struct IOSSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var configurationStore: ServerConfigurationStore
    @ObservedObject var library: AlbumLibraryStore
    @ObservedObject var playback: PlaybackController

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var connectionResult: IOSConnectionResult?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Yorune",
        category: "ServerConnection"
    )

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                Button("Save and Connect") {
                    connect()
                }
                .disabled(isConnecting || !hasInput)
            }

            Section("Language") {
                Picker("Application Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.title)).tag(language)
                    }
                }
            }

            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(LocalizedStringKey(appearance.title)).tag(appearance)
                    }
                }
            }

            Section("About") {
                LabeledContent("Yorune", value: version)
            }
        }
        .navigationTitle("Settings")
        .onAppear(perform: loadConfiguration)
        .alert(item: $connectionResult) { result in
            Alert(
                title: Text(result.title),
                message: result.message.map { Text(verbatim: $0) },
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var hasInput: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private func loadConfiguration() {
        guard let configuration = configurationStore.configuration else { return }
        serverURL = configuration.serverURL
        username = configuration.username
        password = configuration.password
    }

    private func connect() {
        let configuration = ServerConfiguration(
            serverURL: serverURL,
            username: username,
            password: password
        )
        let previousConfiguration = configurationStore.configuration

        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await library.connect(using: configuration)
                if let configuration = configuration.normalized,
                   previousConfiguration?.serverURL != configuration.serverURL
                    || previousConfiguration?.username != configuration.username {
                    playback.stopAndClearQueue()
                }
                connectionResult = .connected
            } catch {
                let result = IOSConnectionResult.failure(error)
                logger.error(
                    "Connection failed: \(result.message ?? "Unknown error", privacy: .public)"
                )
                connectionResult = result
            }
        }
    }
}

private struct IOSConnectionResult: Identifiable {
    enum Kind {
        case connected
        case failure
    }

    let id = UUID()
    let kind: Kind
    let message: String?

    static let connected = IOSConnectionResult(kind: .connected, message: nil)

    static func failure(_ error: Error) -> IOSConnectionResult {
        let localizedError = error as? LocalizedError
        let description = localizedError?.errorDescription ?? error.localizedDescription
        let message = [description, localizedError?.recoverySuggestion]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n\n")
        return IOSConnectionResult(
            kind: .failure,
            message: message.isEmpty ? String(localized: "Unknown connection error.") : message
        )
    }

    var title: LocalizedStringKey {
        switch kind {
        case .connected: "Connected"
        case .failure: "Connection Failed"
        }
    }
}
