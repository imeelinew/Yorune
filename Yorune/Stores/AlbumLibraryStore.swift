import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#endif

@MainActor
final class AlbumLibraryStore: ObservableObject {
    enum State: Equatable {
        case needsConfiguration
        case loading
        case loaded
        case failed
    }

    @Published private(set) var albums: [Album] = []
    @Published private(set) var state: State = .needsConfiguration
    @Published private(set) var isSyncing = false

    private let configurationStore: ServerConfigurationStore
    private let fileManager: FileManager
    private var songsByAlbumID: [String: [Song]] = [:]
    private var lastSuccessfulSyncDate: Date?

    private static let automaticSyncInterval: TimeInterval = 60

    init(
        configurationStore: ServerConfigurationStore,
        fileManager: FileManager = .default
    ) {
        self.configurationStore = configurationStore
        self.fileManager = fileManager
    }

    func reload() async {
        await reload(ignoringAutomaticSyncThrottle: true)
    }

    func runAutomaticSync() async {
        while !Task.isCancelled {
            await reload(ignoringAutomaticSyncThrottle: false)

            do {
                try await Task.sleep(for: .seconds(Self.automaticSyncInterval))
            } catch {
                return
            }
        }
    }

    private func reload(ignoringAutomaticSyncThrottle: Bool) async {
        guard !isSyncing, state != .loading else { return }
        guard let configuration = configurationStore.configuration else {
            albums = []
            songsByAlbumID = [:]
            state = .needsConfiguration
            return
        }
        if !ignoringAutomaticSyncThrottle,
           let lastSuccessfulSyncDate,
           Date.now.timeIntervalSince(lastSuccessfulSyncDate) < Self.automaticSyncInterval {
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        if await load(using: configuration) {
            lastSuccessfulSyncDate = .now
        }
    }

    func connect(using configuration: ServerConfiguration) async throws {
        guard let configuration = configuration.normalized else {
            throw ServerConfigurationError.invalid
        }

        let previousAlbums = albums
        let previousSongs = songsByAlbumID
        state = .loading

        do {
            let albums = try await NavidromeClient(configuration: configuration).fetchAlbums()
            try configurationStore.save(configuration)
            songsByAlbumID.removeAll()
            self.albums = albums
            persistLibraryCache(for: configuration)
            state = .loaded
            lastSuccessfulSyncDate = .now
        } catch {
            restoreLibrary(
                configuration: configuration,
                previousAlbums: previousAlbums,
                previousSongs: previousSongs
            )
            throw error
        }
    }

    func fetchSongs(in album: Album) async throws -> [Song] {
        if let songs = songsByAlbumID[album.id], !songs.isEmpty {
            return songs
        }
        guard let configuration = configurationStore.configuration else {
            throw ServerConfigurationError.invalid
        }

        do {
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
                        artworkURL: song.artworkURL ?? album.artworkURL
                    )
                }
            songsByAlbumID[album.id] = songs
            persistLibraryCache(for: configuration)
            return songs
        } catch {
            if let cached = cachedSongs(for: album.id, configuration: configuration),
               !cached.isEmpty {
                songsByAlbumID[album.id] = cached
                return cached
            }
            throw error
        }
    }

    private func load(using configuration: ServerConfiguration) async -> Bool {
        applyCachedLibrary(for: configuration)
        if albums.isEmpty {
            state = .loading
        }

        do {
            let albums = try await NavidromeClient(configuration: configuration).fetchAlbums()
            self.albums = albums
            let albumIDs = Set(albums.map(\.id))
            songsByAlbumID = songsByAlbumID.filter { albumIDs.contains($0.key) }
            persistLibraryCache(for: configuration)
            state = .loaded
            return true
        } catch {
            if albums.isEmpty {
                state = .failed
            }
            return false
        }
    }

    private func restoreLibrary(
        configuration: ServerConfiguration,
        previousAlbums: [Album],
        previousSongs: [String: [Song]]
    ) {
        applyCachedLibrary(for: configuration)
        if albums.isEmpty, !previousAlbums.isEmpty {
            albums = previousAlbums
            songsByAlbumID = previousSongs
        }
        state = albums.isEmpty ? .failed : .loaded
    }

    private func applyCachedLibrary(for configuration: ServerConfiguration) {
        guard let cache = loadLibraryCache(for: configuration) else { return }
        albums = cache.albums
        songsByAlbumID.merge(cache.songsByAlbumID) { current, _ in current }
        if !albums.isEmpty {
            state = .loaded
        }
    }

    private func cachedSongs(
        for albumID: String,
        configuration: ServerConfiguration
    ) -> [Song]? {
        songsByAlbumID[albumID] ?? loadLibraryCache(for: configuration)?.songsByAlbumID[albumID]
    }

    private func persistLibraryCache(for configuration: ServerConfiguration) {
        let cacheURL = Self.libraryCacheURL(
            for: configuration,
            fileManager: fileManager
        )
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(
                LibraryDiskCache(albums: albums, songsByAlbumID: songsByAlbumID)
            )
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            return
        }
    }

    private func loadLibraryCache(for configuration: ServerConfiguration) -> LibraryDiskCache? {
        let cacheURL = Self.libraryCacheURL(
            for: configuration,
            fileManager: fileManager
        )
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(LibraryDiskCache.self, from: data)
    }

    private static func libraryCacheURL(
        for configuration: ServerConfiguration,
        fileManager: FileManager
    ) -> URL {
        fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Yorune", isDirectory: true)
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent(
            DownloadStore.profileIdentifier(for: configuration),
            isDirectory: true
        )
        .appendingPathComponent("cache.json")
    }
}

private struct LibraryDiskCache: Codable {
    var albums: [Album]
    var songsByAlbumID: [String: [Song]]
}

struct OfflineLibraryManifest: Codable, Equatable {
    let version: Int
    var filenamesBySongID: [String: String]
    var songsBySongID: [String: Song]
    var artworkFilenamesByAlbumID: [String: String]

    static func decode(_ data: Data) throws -> OfflineLibraryManifest {
        let decoder = JSONDecoder()
        if let manifest = try? decoder.decode(OfflineLibraryManifest.self, from: data) {
            return manifest
        }
        return OfflineLibraryManifest(
            version: 1,
            filenamesBySongID: try decoder.decode([String: String].self, from: data),
            songsBySongID: [:],
            artworkFilenamesByAlbumID: [:]
        )
    }

    func validated(in directoryURL: URL, fileManager: FileManager) -> OfflineLibraryManifest {
        let validFilenames = filenamesBySongID.filter { _, filename in
            Self.isSafeFilename(filename)
                && fileManager.fileExists(
                    atPath: directoryURL.appendingPathComponent(filename).path
                )
        }
        let validSongs = songsBySongID.filter { validFilenames[$0.key] != nil }
        let validArtwork = artworkFilenamesByAlbumID.filter { _, filename in
            Self.isSafeFilename(filename)
                && fileManager.fileExists(
                    atPath: directoryURL.appendingPathComponent(filename).path
                )
        }
        return OfflineLibraryManifest(
            version: version,
            filenamesBySongID: validFilenames,
            songsBySongID: validSongs,
            artworkFilenamesByAlbumID: validArtwork
        )
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        filename == URL(fileURLWithPath: filename).lastPathComponent
    }
}

@MainActor
final class DownloadStore: ObservableObject {
    struct Failure: Identifiable {
        let id = UUID()
        let error: Error?

        var message: String {
            guard let error else { return "" }
            let localized = error as? LocalizedError
            return [localized?.errorDescription ?? error.localizedDescription, localized?.recoverySuggestion]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: "\n\n")
        }
    }

    @Published private(set) var downloadedSongIDs: Set<String> = []
    @Published private(set) var downloadingSongIDs: Set<String> = []
    @Published private(set) var offlineAlbums: [Album] = []
    @Published var failure: Failure?

    private let configurationStore: ServerConfigurationStore
    private let fileManager: FileManager
    private let downloadsRootURL: URL
    private let maximumConcurrentDownloads = 3
    private var activeProfileIdentifier: String?
    private var activeDirectoryURL: URL?
    private var filenamesBySongID: [String: String] = [:]
    private var songsBySongID: [String: Song] = [:]
    private var artworkFilenamesByAlbumID: [String: String] = [:]
    private var downloadingArtworkAlbumIDs: Set<String> = []
    private var pendingSongs: [Song] = []
    private var tasksBySongID: [String: Task<Void, Never>] = [:]
    private var configurationCancellable: AnyCancellable?
    private var generation = 0
#if os(iOS)
    private var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
#endif

    init(
        configurationStore: ServerConfigurationStore,
        fileManager: FileManager = .default,
        downloadsRootURL: URL? = nil
    ) {
        self.configurationStore = configurationStore
        self.fileManager = fileManager
        self.downloadsRootURL = downloadsRootURL ?? Self.downloadsRootURL(fileManager: fileManager)
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
            failure = Failure(error: ServerConfigurationError.invalid)
            return
        }

        for song in songs where !isDownloaded(song.id) && !isDownloading(song.id) {
            downloadingSongIDs.insert(song.id)
            pendingSongs.append(song)
        }
        updateBackgroundTask()
        startPendingDownloads()
    }

    func cancel(_ songIDs: Set<String>) {
        guard !songIDs.isEmpty else { return }
        pendingSongs.removeAll { songIDs.contains($0.id) }
        for songID in songIDs {
            tasksBySongID[songID]?.cancel()
            tasksBySongID.removeValue(forKey: songID)
            downloadingSongIDs.remove(songID)
        }
        updateBackgroundTask()
        startPendingDownloads()
    }

    func remove(_ songs: [Song]) {
        activateCurrentProfile()
        let songIDs = Set(songs.map(\.id))
        cancel(songIDs)
        guard let directoryURL = activeDirectoryURL else { return }

        let albumIDs = Set(songs.map(\.albumID))
        for song in songs {
            if let filename = filenamesBySongID.removeValue(forKey: song.id) {
                try? fileManager.removeItem(
                    at: directoryURL.appendingPathComponent(filename)
                )
            }
            songsBySongID.removeValue(forKey: song.id)
            downloadedSongIDs.remove(song.id)
        }
        for albumID in albumIDs {
            removeArtworkIfUnused(albumID: albumID, directoryURL: directoryURL)
        }
        try? persistManifest()
        refreshOfflineLibrary()
    }

    func remove(albumID: String) {
        let songs = songsBySongID.values.filter { $0.albumID == albumID }
        remove(Array(songs))
    }

    func remember(_ songs: [Song]) {
        activateCurrentProfile()
        var changed = false
        for song in songs where downloadedSongIDs.contains(song.id) {
            let stored = Self.song(song, artworkURL: nil)
            if songsBySongID[song.id] != stored {
                songsBySongID[song.id] = stored
                changed = true
            }
        }
        guard changed else { return }
        try? persistManifest()
        refreshOfflineLibrary()
    }

    func localURL(for songID: String) -> URL? {
        guard let directoryURL = activeDirectoryURL,
              let filename = filenamesBySongID[songID] else { return nil }
        let url = directoryURL.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else {
            filenamesBySongID.removeValue(forKey: songID)
            downloadedSongIDs.remove(songID)
            songsBySongID.removeValue(forKey: songID)
            try? persistManifest()
            refreshOfflineLibrary()
            return nil
        }
        return url
    }

    func offlineSongs(in albumID: String) -> [Song] {
        let artworkURL = localArtworkURL(for: albumID)
        return songsBySongID.values
            .filter { $0.albumID == albumID && downloadedSongIDs.contains($0.id) }
            .sorted(by: Self.songSort)
            .map { Self.song($0, artworkURL: artworkURL) }
    }

    func offlineSong(for songID: String) -> Song? {
        guard downloadedSongIDs.contains(songID),
              let song = songsBySongID[songID] else { return nil }
        return Self.song(song, artworkURL: localArtworkURL(for: song.albumID))
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
        updateBackgroundTask()
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
            guard taskGeneration == generation else {
                try? fileManager.removeItem(at: download.temporaryURL)
                return
            }
            try store(
                download,
                songID: song.id,
                song: song,
                directoryURL: directoryURL
            )
            await cacheArtwork(
                for: song,
                directoryURL: directoryURL,
                generation: taskGeneration
            )
        } catch {
            guard !Task.isCancelled,
                  taskGeneration == generation else { return }
            failure = Failure(error: error)
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
        song: Song,
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
        let previousSong = songsBySongID.updateValue(
            Self.song(song, artworkURL: nil),
            forKey: songID
        )
        do {
            try persistManifest()
            downloadedSongIDs.insert(songID)
            refreshOfflineLibrary()
        } catch {
            if let previousFilename {
                filenamesBySongID[songID] = previousFilename
            } else {
                filenamesBySongID.removeValue(forKey: songID)
            }
            if let previousSong {
                songsBySongID[songID] = previousSong
            } else {
                songsBySongID.removeValue(forKey: songID)
            }
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private func cacheArtwork(
        for song: Song,
        directoryURL: URL,
        generation taskGeneration: Int
    ) async {
        guard artworkFilenamesByAlbumID[song.albumID] == nil,
              !downloadingArtworkAlbumIDs.contains(song.albumID),
              let artworkURL = song.artworkURL else { return }

        downloadingArtworkAlbumIDs.insert(song.albumID)
        defer { downloadingArtworkAlbumIDs.remove(song.albumID) }

        do {
            guard let data = await ArtworkCache.shared.data(for: artworkURL),
                  taskGeneration == generation,
                  !Task.isCancelled else { return }

            let filename = "artwork-\(Self.hash(song.albumID)).image"
            try data.write(
                to: directoryURL.appendingPathComponent(filename),
                options: .atomic
            )
            artworkFilenamesByAlbumID[song.albumID] = filename
            try persistManifest()
            refreshOfflineLibrary()
        } catch {
            return
        }
    }

    private func activateCurrentProfile(forceReload: Bool = false) {
        guard let configuration = configurationStore.configuration else {
            resetActiveProfile()
            return
        }
        let identifier = Self.profileIdentifier(for: configuration)
        guard forceReload || identifier != activeProfileIdentifier else { return }

        cancelDownloads()
        activeProfileIdentifier = identifier
        activeDirectoryURL = downloadsRootURL
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
        songsBySongID = [:]
        artworkFilenamesByAlbumID = [:]
        downloadingArtworkAlbumIDs = []
        downloadedSongIDs = []
        offlineAlbums = []
    }

    private func cancelDownloads() {
        generation += 1
        tasksBySongID.values.forEach { $0.cancel() }
        tasksBySongID = [:]
        pendingSongs = []
        downloadingSongIDs = []
        downloadingArtworkAlbumIDs = []
        updateBackgroundTask()
    }

    private func loadManifest() {
        guard let directoryURL = activeDirectoryURL else {
            filenamesBySongID = [:]
            songsBySongID = [:]
            artworkFilenamesByAlbumID = [:]
            downloadedSongIDs = []
            offlineAlbums = []
            return
        }
        guard let data = try? Data(
            contentsOf: directoryURL.appendingPathComponent("manifest.json")
        ) else {
            filenamesBySongID = [:]
            songsBySongID = [:]
            artworkFilenamesByAlbumID = [:]
            downloadedSongIDs = []
            offlineAlbums = []
            return
        }

        let manifest = (try? OfflineLibraryManifest.decode(data))?
            .validated(in: directoryURL, fileManager: fileManager)
            ?? OfflineLibraryManifest(
                version: 1,
                filenamesBySongID: [:],
                songsBySongID: [:],
                artworkFilenamesByAlbumID: [:]
            )

        filenamesBySongID = manifest.filenamesBySongID
        songsBySongID = manifest.songsBySongID
        artworkFilenamesByAlbumID = manifest.artworkFilenamesByAlbumID
        downloadedSongIDs = Set(filenamesBySongID.keys)
        refreshOfflineLibrary()
    }

    private func persistManifest() throws {
        guard let directoryURL = activeDirectoryURL else { return }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(
            OfflineLibraryManifest(
                version: 1,
                filenamesBySongID: filenamesBySongID,
                songsBySongID: songsBySongID,
                artworkFilenamesByAlbumID: artworkFilenamesByAlbumID
            )
        )
        try data.write(
            to: directoryURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private func refreshOfflineLibrary() {
        let albumIDs = Set(
            songsBySongID.values
                .filter { downloadedSongIDs.contains($0.id) }
                .map(\.albumID)
        )
        offlineAlbums = albumIDs.compactMap { albumID in
            guard let song = songsBySongID.values.first(where: {
                $0.albumID == albumID && downloadedSongIDs.contains($0.id)
            }) else { return nil }
            return Album(
                id: albumID,
                title: song.albumTitle,
                artist: song.artist,
                artworkURL: localArtworkURL(for: albumID),
                lastPlayed: nil
            )
        }
        .sortedByLastPlayed()
    }

    private func localArtworkURL(for albumID: String) -> URL? {
        guard let directoryURL = activeDirectoryURL,
              let filename = artworkFilenamesByAlbumID[albumID] else { return nil }
        let url = directoryURL.appendingPathComponent(filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func removeArtworkIfUnused(albumID: String, directoryURL: URL) {
        let hasRemainingSongs = songsBySongID.values.contains {
            $0.albumID == albumID && downloadedSongIDs.contains($0.id)
        }
        guard !hasRemainingSongs,
              let filename = artworkFilenamesByAlbumID.removeValue(forKey: albumID) else {
            return
        }
        try? fileManager.removeItem(at: directoryURL.appendingPathComponent(filename))
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

    nonisolated static func profileIdentifier(for configuration: ServerConfiguration) -> String {
        hash("\(configuration.serverURL)\n\(configuration.username)")
    }

    private nonisolated static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func song(_ song: Song, artworkURL: URL?) -> Song {
        Song(
            id: song.id,
            title: song.title,
            artist: song.artist,
            albumID: song.albumID,
            albumTitle: song.albumTitle,
            duration: song.duration,
            trackNumber: song.trackNumber,
            discNumber: song.discNumber,
            artworkURL: artworkURL
        )
    }

    private static func songSort(_ lhs: Song, _ rhs: Song) -> Bool {
        let lhsDisc = lhs.discNumber ?? 1
        let rhsDisc = rhs.discNumber ?? 1
        if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }
        let lhsTrack = lhs.trackNumber ?? .max
        let rhsTrack = rhs.trackNumber ?? .max
        if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func updateBackgroundTask() {
#if os(iOS)
        let hasWork = !pendingSongs.isEmpty
            || !tasksBySongID.isEmpty
            || !downloadingSongIDs.isEmpty
        if hasWork {
            beginBackgroundTask()
        } else {
            endBackgroundTask()
        }
#endif
    }

#if os(iOS)
    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
#endif
}
