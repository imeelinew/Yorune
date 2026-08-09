import CryptoKit
import Foundation

actor NavidromeClient {
    private let configuration: ServerConfiguration
    private let session: URLSession
    private let salt: String
    private let token: String

    init(configuration: ServerConfiguration) {
        self.configuration = configuration

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        self.session = URLSession(configuration: sessionConfiguration)

        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.salt = salt
        self.token = Self.md5(configuration.password + salt)
    }

    func fetchAlbums() async throws -> [Album] {
        let pageSize = 500
        var offset = 0
        var albums: [Album] = []

        while true {
            let url = try makeURL(
                action: "getAlbumList2",
                queryItems: [
                    URLQueryItem(name: "type", value: "alphabeticalByName"),
                    URLQueryItem(name: "size", value: String(pageSize)),
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "f", value: "json")
                ]
            )
            let data = try await data(from: url)
            let envelope = try JSONDecoder().decode(SubsonicEnvelope.self, from: data)

            guard envelope.response.status == "ok" else {
                throw NavidromeError.server
            }

            let page = envelope.response.albumList?.albums ?? []
            albums.append(contentsOf: try page.map { album in
                Album(
                    id: album.id,
                    title: album.name,
                    artworkURL: try album.coverArt.map { coverArt in
                        try makeURL(
                            action: "getCoverArt",
                            queryItems: [
                                URLQueryItem(name: "id", value: coverArt),
                                URLQueryItem(name: "size", value: "600")
                            ]
                        )
                    }
                )
            })

            guard page.count == pageSize else { break }
            offset += page.count
        }

        return albums
    }

    func fetchSongs(in albumID: String) async throws -> [Song] {
        let url = try makeURL(
            action: "getAlbum",
            queryItems: [
                URLQueryItem(name: "id", value: albumID),
                URLQueryItem(name: "f", value: "json")
            ]
        )
        let data = try await data(from: url)
        let envelope = try JSONDecoder().decode(SubsonicEnvelope.self, from: data)

        guard envelope.response.status == "ok",
              let album = envelope.response.album else {
            throw NavidromeError.server
        }

        return (album.songs ?? []).map { song in
            Song(
                id: song.id,
                title: song.title,
                artist: song.artist ?? "",
                albumID: albumID,
                albumTitle: song.album ?? album.name ?? "",
                duration: song.duration ?? 0,
                trackNumber: song.track,
                discNumber: song.discNumber,
                artworkURL: nil
            )
        }
    }

    func streamURL(for songID: String) throws -> URL {
        try makeURL(
            action: "stream",
            queryItems: [URLQueryItem(name: "id", value: songID)]
        )
    }

    private func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200 ... 299).contains(response.statusCode) else {
            throw NavidromeError.network
        }
        return data
    }

    private func makeURL(action: String, queryItems: [URLQueryItem]) throws -> URL {
        guard let baseURL = URL(string: configuration.serverURL) else {
            throw NavidromeError.invalidURL
        }

        let endpoint = baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("\(action).view")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw NavidromeError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "u", value: configuration.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "Yorune")
        ] + queryItems

        guard let url = components.url else {
            throw NavidromeError.invalidURL
        }
        return url
    }

    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct SubsonicEnvelope: Decodable {
    let response: SubsonicResponse

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

private struct SubsonicResponse: Decodable {
    let status: String
    let albumList: SubsonicAlbumList?
    let album: SubsonicAlbumDetail?

    enum CodingKeys: String, CodingKey {
        case status
        case albumList = "albumList2"
        case album
    }
}

private struct SubsonicAlbumList: Decodable {
    let albums: [SubsonicAlbum]

    enum CodingKeys: String, CodingKey {
        case albums = "album"
    }
}

private struct SubsonicAlbum: Decodable {
    let id: String
    let name: String
    let coverArt: String?
}

private struct SubsonicAlbumDetail: Decodable {
    let name: String?
    let songs: [SubsonicSong]?

    enum CodingKeys: String, CodingKey {
        case name
        case songs = "song"
    }
}

private struct SubsonicSong: Decodable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Double?
    let track: Int?
    let discNumber: Int?
}

enum NavidromeError: Error {
    case invalidURL
    case network
    case server
}
