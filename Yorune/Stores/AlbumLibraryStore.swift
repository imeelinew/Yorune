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
    private var songsByAlbumID: [String: [Song]] = [:]

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
            songsByAlbumID.removeAll()
            self.albums = albums
            state = .loaded
        } catch {
            state = .failed
            throw error
        }
    }

    func fetchSongs(in album: Album) async throws -> [Song] {
        if let songs = songsByAlbumID[album.id] {
            return songs
        }
        guard let configuration = configurationStore.configuration else {
            throw ServerConfigurationError.invalid
        }

        let songs = try await NavidromeClient(configuration: configuration)
            .fetchSongs(in: album.id)
            .map { song in
                Song(
                    id: song.id,
                    title: song.title,
                    artist: song.artist,
                    albumID: song.albumID,
                    albumTitle: song.albumTitle,
                    duration: song.duration,
                    trackNumber: song.trackNumber,
                    discNumber: song.discNumber,
                    artworkURL: album.artworkURL
                )
            }
        songsByAlbumID[album.id] = songs
        return songs
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
