import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

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

@MainActor
final class DownloadStore: ObservableObject {
    struct Failure: Identifiable {
        let id = UUID()
    }

    @Published private(set) var downloadedSongIDs: Set<String> = []
    @Published private(set) var downloadingSongIDs: Set<String> = []
    @Published var failure: Failure?

    private let configurationStore: ServerConfigurationStore
    private let fileManager: FileManager
    private let maximumConcurrentDownloads = 3
    private var activeProfileIdentifier: String?
    private var activeDirectoryURL: URL?
    private var filenamesBySongID: [String: String] = [:]
    private var pendingSongs: [Song] = []
    private var tasksBySongID: [String: Task<Void, Never>] = [:]
    private var configurationCancellable: AnyCancellable?
    private var generation = 0

    init(
        configurationStore: ServerConfigurationStore,
        fileManager: FileManager = .default
    ) {
        self.configurationStore = configurationStore
        self.fileManager = fileManager
        activateCurrentProfile()
        configurationCancellable = configurationStore.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.activateCurrentProfile(forceReload: true)
                }
            }
    }

    deinit {
        tasksBySongID.values.forEach { $0.cancel() }
    }

    func isDownloaded(_ songID: String) -> Bool {
        downloadedSongIDs.contains(songID)
    }

    func isDownloading(_ songID: String) -> Bool {
        downloadingSongIDs.contains(songID)
    }

    func download(_ song: Song) {
        download([song])
    }

    func download(_ songs: [Song]) {
        activateCurrentProfile()
        guard activeDirectoryURL != nil,
              configurationStore.configuration != nil else {
            failure = Failure()
            return
        }

        for song in songs where !isDownloaded(song.id) && !isDownloading(song.id) {
            downloadingSongIDs.insert(song.id)
            pendingSongs.append(song)
        }
        startPendingDownloads()
    }

    func localURL(for songID: String) -> URL? {
        guard let directoryURL = activeDirectoryURL,
              let filename = filenamesBySongID[songID] else { return nil }
        let url = directoryURL.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else {
            filenamesBySongID.removeValue(forKey: songID)
            downloadedSongIDs.remove(songID)
            try? persistManifest()
            return nil
        }
        return url
    }

    func dismissFailure() {
        failure = nil
    }

    private func startPendingDownloads() {
        while tasksBySongID.count < maximumConcurrentDownloads,
              !pendingSongs.isEmpty {
            let song = pendingSongs.removeFirst()
            let taskGeneration = generation
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.performDownload(song, generation: taskGeneration)
            }
            tasksBySongID[song.id] = task
        }
    }

    private func performDownload(_ song: Song, generation taskGeneration: Int) async {
        defer {
            finishDownload(songID: song.id, generation: taskGeneration)
        }

        guard taskGeneration == generation,
              let configuration = configurationStore.configuration,
              let directoryURL = activeDirectoryURL else { return }

        do {
            let download = try await NavidromeClient(configuration: configuration)
                .download(songID: song.id)
            try Task.checkCancellation()
            guard taskGeneration == generation else { return }
            try store(
                download,
                songID: song.id,
                directoryURL: directoryURL
            )
        } catch {
            guard !Task.isCancelled,
                  taskGeneration == generation else { return }
            failure = Failure()
        }
    }

    private func finishDownload(songID: String, generation taskGeneration: Int) {
        guard taskGeneration == generation else { return }
        tasksBySongID.removeValue(forKey: songID)
        downloadingSongIDs.remove(songID)
        startPendingDownloads()
    }

    private func store(
        _ download: NavidromeDownload,
        songID: String,
        directoryURL: URL
    ) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let filename = "\(Self.hash(songID)).\(fileExtension(for: download))"
        let destinationURL = directoryURL.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: download.temporaryURL, to: destinationURL)

        let previousFilename = filenamesBySongID.updateValue(filename, forKey: songID)
        do {
            try persistManifest()
            downloadedSongIDs.insert(songID)
        } catch {
            if let previousFilename {
                filenamesBySongID[songID] = previousFilename
            } else {
                filenamesBySongID.removeValue(forKey: songID)
            }
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private func activateCurrentProfile(forceReload: Bool = false) {
        guard let configuration = configurationStore.configuration else {
            resetActiveProfile()
            return
        }
        let identifier = Self.hash(
            "\(configuration.serverURL)\n\(configuration.username)"
        )
        guard forceReload || identifier != activeProfileIdentifier else { return }

        cancelDownloads()
        activeProfileIdentifier = identifier
        activeDirectoryURL = Self.downloadsRootURL(fileManager: fileManager)
            .appendingPathComponent(identifier, isDirectory: true)
        loadManifest()
    }

    private func resetActiveProfile() {
        guard activeProfileIdentifier != nil
                || !downloadedSongIDs.isEmpty
                || !downloadingSongIDs.isEmpty else { return }
        cancelDownloads()
        activeProfileIdentifier = nil
        activeDirectoryURL = nil
        filenamesBySongID = [:]
        downloadedSongIDs = []
    }

    private func cancelDownloads() {
        generation += 1
        tasksBySongID.values.forEach { $0.cancel() }
        tasksBySongID = [:]
        pendingSongs = []
        downloadingSongIDs = []
    }

    private func loadManifest() {
        guard let directoryURL = activeDirectoryURL else {
            filenamesBySongID = [:]
            downloadedSongIDs = []
            return
        }
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(
                [String: String].self,
                from: data
              ) else {
            filenamesBySongID = [:]
            downloadedSongIDs = []
            return
        }

        filenamesBySongID = manifest.filter { _, filename in
            filename == URL(fileURLWithPath: filename).lastPathComponent
                && fileManager.fileExists(
                    atPath: directoryURL.appendingPathComponent(filename).path
                )
        }
        downloadedSongIDs = Set(filenamesBySongID.keys)
    }

    private func persistManifest() throws {
        guard let directoryURL = activeDirectoryURL else { return }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(filenamesBySongID)
        try data.write(
            to: directoryURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private func fileExtension(for download: NavidromeDownload) -> String {
        if let mimeType = download.mimeType,
           let preferredExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension,
           let fileExtension = Self.validatedFileExtension(preferredExtension) {
            return fileExtension
        }
        if let suggestedFilename = download.suggestedFilename,
           let fileExtension = Self.validatedFileExtension(
            URL(fileURLWithPath: suggestedFilename).pathExtension
           ),
           fileExtension != "view" {
            return fileExtension
        }
        return "audio"
    }

    private static func validatedFileExtension(_ value: String) -> String? {
        let value = value.lowercased()
        guard !value.isEmpty,
              value.count <= 10,
              value.unicodeScalars.allSatisfy(
                CharacterSet.alphanumerics.contains
              ) else { return nil }
        return value
    }

    private static func downloadsRootURL(fileManager: FileManager) -> URL {
        fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Yorune", isDirectory: true)
        .appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
