import Foundation

@MainActor
final class AlbumLibraryStore: ObservableObject {
    enum State {
        case needsConfiguration
        case loading
        case loaded
        case failed
    }

    @Published private(set) var albums: [Album] = []
    @Published private(set) var state: State = .needsConfiguration

    private let configurationStore: ServerConfigurationStore

    init(configurationStore: ServerConfigurationStore) {
        self.configurationStore = configurationStore
    }

    func reload() async {
        guard state != .loading else { return }
        guard let configuration = configurationStore.configuration else {
            albums = []
            state = .needsConfiguration
            return
        }

        await load(using: configuration)
    }

    func connect(using configuration: ServerConfiguration) async throws {
        guard let configuration = configuration.normalized else {
            throw ServerConfigurationError.invalid
        }

        state = .loading

        do {
            let albums = try await NavidromeClient(configuration: configuration).fetchAlbums()
            try configurationStore.save(configuration)
            self.albums = albums
            state = .loaded
        } catch {
            state = .failed
            throw error
        }
    }

    private func load(using configuration: ServerConfiguration) async {
        state = .loading

        do {
            albums = try await NavidromeClient(configuration: configuration).fetchAlbums()
            state = .loaded
        } catch {
            albums = []
            state = .failed
        }
    }
}
