import SwiftUI

struct ServerSettingsView: View {
    @ObservedObject var configurationStore: ServerConfigurationStore
    @ObservedObject var library: AlbumLibraryStore
    @ObservedObject var playback: PlaybackController

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var result: ConnectionResult?

    var body: some View {
        PreferencesForm {
            PreferencesRow(label: "Server URL") {
                TextField("Server URL", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
            }

            PreferencesRow(label: "Username") {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
            }

            PreferencesRow(label: "Password") {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
            }

            PreferencesRow(label: "") {
                Button("Save and Connect") {
                    connect()
                }
                .disabled(isConnecting || !hasInput)
            }
        }
        .onAppear(perform: loadConfiguration)
        .alert(item: $result) { result in
            Alert(
                title: Text(result.title),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var hasInput: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
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
                   (
                       previousConfiguration?.serverURL != configuration.serverURL
                           || previousConfiguration?.username != configuration.username
                   ) {
                    playback.stopAndClearQueue()
                }
                result = .success
            } catch {
                result = .failure
            }
        }
    }
}

private enum ConnectionResult: String, Identifiable {
    case success
    case failure

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .success: "Connected"
        case .failure: "Connection Failed"
        }
    }
}
