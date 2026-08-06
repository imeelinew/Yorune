import SwiftUI

struct ServerSettingsView: View {
    @ObservedObject var configurationStore: ServerConfigurationStore
    @ObservedObject var library: AlbumLibraryStore

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var result: ConnectionResult?

    var body: some View {
        PreferencesForm {
            PreferencesRow(label: "服务器地址") {
                TextField("服务器地址", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
            }

            PreferencesRow(label: "用户名") {
                TextField("用户名", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
            }

            PreferencesRow(label: "密码") {
                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
            }

            PreferencesRow(label: "") {
                Button("保存并连接") {
                    connect()
                }
                .disabled(isConnecting || !hasInput)
            }
        }
        .onAppear(perform: loadConfiguration)
        .alert(item: $result) { result in
            Alert(
                title: Text(result.title),
                dismissButton: .default(Text("好"))
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

        isConnecting = true
        Task {
            defer { isConnecting = false }

            do {
                try await library.connect(using: configuration)
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

    var title: String {
        switch self {
        case .success: "连接成功"
        case .failure: "连接失败"
        }
    }
}
