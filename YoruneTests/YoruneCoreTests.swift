import Foundation
import XCTest
@testable import Yorune

final class YoruneCoreTests: XCTestCase {
    func testServerConfigurationNormalization() {
        let configuration = ServerConfiguration(
            serverURL: "  https://music.example.com///  ",
            username: "  eli  ",
            password: "secret"
        ).normalized

        XCTAssertEqual(configuration?.serverURL, "https://music.example.com")
        XCTAssertEqual(configuration?.username, "eli")
        XCTAssertEqual(configuration?.password, "secret")
    }

    func testServerConfigurationRejectsInvalidInput() {
        XCTAssertNil(
            ServerConfiguration(
                serverURL: "file:///tmp/music",
                username: "eli",
                password: "secret"
            ).normalized
        )
    }

    func testDownloadProfilesAreIsolatedByServerAndUsername() {
        let first = ServerConfiguration(
            serverURL: "https://one.example.com",
            username: "eli",
            password: "secret"
        )
        let second = ServerConfiguration(
            serverURL: "https://two.example.com",
            username: "eli",
            password: "secret"
        )
        let third = ServerConfiguration(
            serverURL: "https://one.example.com",
            username: "other",
            password: "secret"
        )

        XCTAssertNotEqual(
            DownloadStore.profileIdentifier(for: first),
            DownloadStore.profileIdentifier(for: second)
        )
        XCTAssertNotEqual(
            DownloadStore.profileIdentifier(for: first),
            DownloadStore.profileIdentifier(for: third)
        )
    }

    func testLegacyDownloadManifestMigration() throws {
        let data = try JSONEncoder().encode(["song-1": "song-1.m4a"])
        let manifest = try OfflineLibraryManifest.decode(data)

        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.filenamesBySongID, ["song-1": "song-1.m4a"])
        XCTAssertTrue(manifest.songsBySongID.isEmpty)
        XCTAssertTrue(manifest.artworkFilenamesByAlbumID.isEmpty)
    }

    func testManifestDropsMissingAndUnsafeFiles() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try Data().write(to: directoryURL.appendingPathComponent("valid.m4a"))
        let validSong = makeSong(id: "valid")
        let missingSong = makeSong(id: "missing")
        let manifest = OfflineLibraryManifest(
            version: 1,
            filenamesBySongID: [
                "valid": "valid.m4a",
                "missing": "missing.m4a",
                "unsafe": "../outside.m4a"
            ],
            songsBySongID: [
                "valid": validSong,
                "missing": missingSong
            ],
            artworkFilenamesByAlbumID: ["album": "missing.image"]
        )

        let validated = manifest.validated(
            in: directoryURL,
            fileManager: .default
        )
        XCTAssertEqual(validated.filenamesBySongID, ["valid": "valid.m4a"])
        XCTAssertEqual(validated.songsBySongID, ["valid": validSong])
        XCTAssertTrue(validated.artworkFilenamesByAlbumID.isEmpty)
    }

    func testManifestRoundTripPreservesSongMetadata() throws {
        let song = makeSong(id: "song-1")
        let manifest = OfflineLibraryManifest(
            version: 1,
            filenamesBySongID: ["song-1": "song-1.m4a"],
            songsBySongID: ["song-1": song],
            artworkFilenamesByAlbumID: ["album": "artwork.image"]
        )

        let decoded = try OfflineLibraryManifest.decode(try JSONEncoder().encode(manifest))

        XCTAssertEqual(decoded.filenamesBySongID, ["song-1": "song-1.m4a"])
        XCTAssertEqual(decoded.songsBySongID, ["song-1": song])
        XCTAssertEqual(decoded.artworkFilenamesByAlbumID, ["album": "artwork.image"])
    }

    @MainActor
    func testDownloadStoreReloadsPersistedLibrary() throws {
        let (configurationStore, rootURL, cleanup) = try makeDownloadStoreEnvironment()
        defer { cleanup() }

        let configuration = try XCTUnwrap(configurationStore.configuration)
        let directoryURL = rootURL.appendingPathComponent(
            DownloadStore.profileIdentifier(for: configuration),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let song = makeSong(id: "song-1")
        try Data("audio".utf8).write(to: directoryURL.appendingPathComponent("song-1.m4a"))
        try JSONEncoder().encode(
            OfflineLibraryManifest(
                version: 1,
                filenamesBySongID: ["song-1": "song-1.m4a"],
                songsBySongID: ["song-1": song],
                artworkFilenamesByAlbumID: [:]
            )
        ).write(to: directoryURL.appendingPathComponent("manifest.json"))

        let downloads = DownloadStore(
            configurationStore: configurationStore,
            downloadsRootURL: rootURL
        )

        XCTAssertTrue(downloads.isDownloaded("song-1"))
        XCTAssertEqual(downloads.offlineAlbums.map(\.id), ["album"])
        XCTAssertEqual(downloads.offlineSongs(in: "album").map(\.id), ["song-1"])
        XCTAssertNotNil(downloads.localURL(for: "song-1"))

        downloads.remove([song])

        XCTAssertFalse(downloads.isDownloaded("song-1"))
        XCTAssertTrue(downloads.offlineAlbums.isEmpty)
        XCTAssertNil(downloads.localURL(for: "song-1"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent("song-1.m4a").path
            )
        )
    }

    @MainActor
    func testDownloadStoreBackfillsLegacyManifestMetadata() throws {
        let (configurationStore, rootURL, cleanup) = try makeDownloadStoreEnvironment()
        defer { cleanup() }

        let configuration = try XCTUnwrap(configurationStore.configuration)
        let directoryURL = rootURL.appendingPathComponent(
            DownloadStore.profileIdentifier(for: configuration),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: directoryURL.appendingPathComponent("song-1.m4a"))
        try JSONEncoder().encode(["song-1": "song-1.m4a"])
            .write(to: directoryURL.appendingPathComponent("manifest.json"))

        let downloads = DownloadStore(
            configurationStore: configurationStore,
            downloadsRootURL: rootURL
        )
        let song = makeSong(id: "song-1")

        XCTAssertTrue(downloads.isDownloaded("song-1"))
        XCTAssertTrue(downloads.offlineAlbums.isEmpty)

        downloads.remember([song])

        XCTAssertEqual(downloads.offlineAlbums.map(\.id), ["album"])
        XCTAssertEqual(downloads.offlineSongs(in: "album").first?.title, "Song")
    }

    func testPlaybackStateRestoreClampsElapsedTime() {
        let song = makeSong(id: "song", duration: 180)
        let snapshot = PlaybackStateSnapshot(
            serverURL: "https://music.example.com",
            username: "eli",
            queue: [song],
            currentIndex: 0,
            elapsedTime: 240
        )
        let restored = snapshot.restored(
            for: ServerConfiguration(
                serverURL: "https://music.example.com",
                username: "eli",
                password: "secret"
            )
        )

        XCTAssertEqual(restored?.queue, [song])
        XCTAssertEqual(restored?.currentIndex, 0)
        XCTAssertEqual(restored?.elapsedTime, 180)
    }

    func testPlaybackStateDoesNotCrossServerProfiles() {
        let snapshot = PlaybackStateSnapshot(
            serverURL: "https://one.example.com",
            username: "eli",
            queue: [makeSong(id: "song")],
            currentIndex: 0,
            elapsedTime: 10
        )

        XCTAssertNil(
            snapshot.restored(
                for: ServerConfiguration(
                    serverURL: "https://two.example.com",
                    username: "eli",
                    password: "secret"
                )
            )
        )
    }

    func testPlaybackURLPrefersDownloadedFile() async throws {
        let localURL = URL(fileURLWithPath: "/tmp/local.m4a")
        var requestedRemoteURL = false

        let result = try await PlaybackURLResolver.resolve(localURL: localURL) {
            requestedRemoteURL = true
            return URL(string: "https://music.example.com/stream")!
        }

        XCTAssertEqual(result, localURL)
        XCTAssertFalse(requestedRemoteURL)
    }

    func testAlbumsSortByMostRecentPlayThenTitle() {
        let recent = Date(timeIntervalSince1970: 200)
        let older = Date(timeIntervalSince1970: 100)
        let albums = [
            Album(id: "never-z", title: "Zulu", artist: "", artworkURL: nil, lastPlayed: nil),
            Album(id: "older", title: "Older", artist: "", artworkURL: nil, lastPlayed: older),
            Album(id: "never-a", title: "Alpha", artist: "", artworkURL: nil, lastPlayed: nil),
            Album(id: "recent-b", title: "Bravo", artist: "", artworkURL: nil, lastPlayed: recent),
            Album(id: "recent-a", title: "Alpha Recent", artist: "", artworkURL: nil, lastPlayed: recent)
        ]

        XCTAssertEqual(
            albums.sortedByLastPlayed().map(\.id),
            ["recent-a", "recent-b", "older", "never-a", "never-z"]
        )
    }

    func testNavidromeClientAcceptsAnEmptyAlbumList() async throws {
        let session = makeSession(
            body: #"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{}}}"#
        )
        let client = NavidromeClient(
            configuration: makeServerConfiguration(),
            session: session
        )

        let albums = try await client.fetchAlbums()

        XCTAssertTrue(albums.isEmpty)
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/rest/getAlbumList2.view")
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.port, 4533)
        let queryNames = Set(components.queryItems?.map(\.name) ?? [])
        XCTAssertTrue(["u", "t", "s", "v", "c"].allSatisfy(queryNames.contains))
        XCTAssertFalse(request.url?.absoluteString.contains("secret") == true)
    }

    func testNavidromeClientMapsAlbumMetadataAndArtwork() async throws {
        let session = makeSession(
            body: #"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[{"id":"album-1","name":"Imaginal Disk","artist":"Magdalena Bay","coverArt":"album-cover","played":"2026-08-30T21:14:33.456Z"}]}}}"#
        )
        let client = NavidromeClient(
            configuration: makeServerConfiguration(),
            session: session
        )

        let albums = try await client.fetchAlbums()
        let album = try XCTUnwrap(albums.first)

        XCTAssertEqual(album.id, "album-1")
        XCTAssertEqual(album.title, "Imaginal Disk")
        XCTAssertEqual(album.artist, "Magdalena Bay")
        XCTAssertEqual(
            album.lastPlayed,
            ISO8601DateFormatter().date(from: "2026-08-30T21:14:33Z")
        )
        let artworkComponents = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(album.artworkURL),
                resolvingAgainstBaseURL: false
            )
        )
        XCTAssertEqual(artworkComponents.path, "/rest/getCoverArt.view")
        XCTAssertEqual(
            artworkComponents.queryItems?.first(where: { $0.name == "id" })?.value,
            "album-cover"
        )
    }

    func testNavidromeClientMapsAndSortsCurrentSongMetadata() async throws {
        let session = makeSession(
            body: #"{"subsonic-response":{"status":"ok","version":"1.16.1","album":{"id":"album-1","name":"Imaginal Disk","coverArt":"album-cover","song":[{"id":"song-2","title":"Killing Time","artist":"Magdalena Bay","album":"Imaginal Disk","coverArt":"song-cover","duration":205,"track":2,"discNumber":1},{"id":"song-1","title":"She Looked Like Me!","artist":"Magdalena Bay","album":"Imaginal Disk","duration":193,"track":1,"discNumber":1}]}}}"#
        )
        let client = NavidromeClient(
            configuration: makeServerConfiguration(),
            session: session
        )

        let songs = try await client.fetchSongs(in: "album-1")

        XCTAssertEqual(songs.map(\.id), ["song-1", "song-2"])
        XCTAssertEqual(songs.map(\.title), ["She Looked Like Me!", "Killing Time"])
        XCTAssertEqual(songs.map(\.albumTitle), ["Imaginal Disk", "Imaginal Disk"])
        XCTAssertEqual(songs.map(\.trackNumber), [1, 2])
        let artworkIDs = try songs.map { song in
            URLComponents(
                url: try XCTUnwrap(song.artworkURL),
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "id" })?.value
        }
        XCTAssertEqual(artworkIDs, ["album-cover", "song-cover"])
    }

    func testArtworkCacheKeyIgnoresRotatingAuthenticationParameters() throws {
        let first = try XCTUnwrap(
            URL(
                string: "https://music.example.com/rest/getCoverArt.view?u=eli&t=token-one&s=salt-one&v=1.16.1&c=Yorune&id=album-cover&size=600"
            )
        )
        let second = try XCTUnwrap(
            URL(
                string: "https://MUSIC.example.com/rest/getCoverArt.view?c=AnotherClient&v=1.16.1&s=salt-two&t=token-two&u=other&id=album-cover&size=600"
            )
        )

        XCTAssertEqual(
            ArtworkCacheKey.value(for: first),
            ArtworkCacheKey.value(for: second)
        )
        XCTAssertFalse(ArtworkCacheKey.value(for: first).contains("token-one"))
        XCTAssertFalse(ArtworkCacheKey.value(for: first).contains("salt-one"))
    }

    func testArtworkCacheKeyDistinguishesDifferentCovers() throws {
        let first = try XCTUnwrap(
            URL(string: "https://music.example.com/rest/getCoverArt.view?id=cover-one&size=600")
        )
        let second = try XCTUnwrap(
            URL(string: "https://music.example.com/rest/getCoverArt.view?id=cover-two&size=600")
        )

        XCTAssertNotEqual(
            ArtworkCacheKey.value(for: first),
            ArtworkCacheKey.value(for: second)
        )
    }

    func testNavidromeClientPreservesAuthenticationFailure() async throws {
        let session = makeSession(
            body: #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#
        )
        let client = NavidromeClient(
            configuration: makeServerConfiguration(),
            session: session
        )

        do {
            _ = try await client.fetchAlbums()
            XCTFail("Expected authentication failure")
        } catch let error as NavidromeError {
            XCTAssertEqual(
                error,
                .server(code: 40, message: "Wrong username or password")
            )
            XCTAssertNotNil(error.errorDescription)
        }
    }

    func testNavidromeNetworkFailureHasRecoverySuggestion() {
        let error = NavidromeError.transport(.cannotConnectToHost)

        XCTAssertNotNil(error.errorDescription)
        XCTAssertNotNil(error.recoverySuggestion)
    }

    @MainActor
    private func makeDownloadStoreEnvironment() throws -> (
        ServerConfigurationStore,
        URL,
        () -> Void
    ) {
        let suiteName = "YoruneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let configurationStore = ServerConfigurationStore(
            defaults: defaults,
            keychain: MemoryKeychainStore()
        )
        try configurationStore.save(makeServerConfiguration())
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return (configurationStore, rootURL, {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        })
    }

    private func makeServerConfiguration() -> ServerConfiguration {
        ServerConfiguration(
            serverURL: "http://music.example.com:4533",
            username: "eli",
            password: "secret"
        )
    }

    private func makeSession(body: String, statusCode: Int = 200) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.response = (
            statusCode: statusCode,
            data: Data(body.utf8)
        )
        MockURLProtocol.lastRequest = nil
        return URLSession(configuration: configuration)
    }

    private func makeSong(id: String, duration: Double = 120) -> Song {
        Song(
            id: id,
            title: "Song",
            artist: "Artist",
            albumID: "album",
            albumTitle: "Album",
            duration: duration,
            trackNumber: 1,
            discNumber: 1,
            artworkURL: nil
        )
    }
}

private final class MemoryKeychainStore: KeychainStoring {
    private var values: [String: String] = [:]

    func read(service: String, account: String) throws -> String? {
        values["\(service)|\(account)"]
    }

    func save(_ value: String, service: String, account: String) throws {
        values["\(service)|\(account)"] = value
    }
}

private final class MockURLProtocol: URLProtocol {
    static var response = (statusCode: 200, data: Data())
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.response.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
