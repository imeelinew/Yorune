import CryptoKit
import Foundation

actor NavidromeClient {
    private let configuration: ServerConfiguration
    private let session: URLSession
    private let salt: String
    private let token: String

    init(configuration: ServerConfiguration, session: URLSession? = nil) {
        self.configuration = configuration

        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            sessionConfiguration.urlCache = nil
            sessionConfiguration.timeoutIntervalForRequest = 60
            sessionConfiguration.timeoutIntervalForResource = 60 * 60
            self.session = URLSession(configuration: sessionConfiguration)
        }

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
            let envelope = try decode(data)

            guard envelope.response.status == "ok" else {
                throw NavidromeError.server(
                    code: envelope.response.error?.code,
                    message: envelope.response.error?.message
                )
            }

            let page = envelope.response.albumList?.albums ?? []
            albums.append(contentsOf: try page.map { album in
                Album(
                    id: album.id,
                    title: album.name,
                    artworkURL: try artworkURL(for: album.coverArt),
                    lastPlayed: album.played?.date
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
        let envelope = try decode(data)

        guard envelope.response.status == "ok" else {
            throw NavidromeError.server(
                code: envelope.response.error?.code,
                message: envelope.response.error?.message
            )
        }
        guard let album = envelope.response.album else {
            throw NavidromeError.invalidResponse
        }

        let albumArtworkURL = try artworkURL(for: album.coverArt)
        return try (album.songs ?? [])
            .map { song in
                Song(
                    id: song.id,
                    title: song.title,
                    artist: song.artist ?? "",
                    albumID: albumID,
                    albumTitle: song.album ?? album.name ?? "",
                    duration: song.duration ?? 0,
                    trackNumber: song.track,
                    discNumber: song.discNumber,
                    artworkURL: try artworkURL(for: song.coverArt) ?? albumArtworkURL
                )
            }
            .sorted(by: Self.songSort)
    }

    func streamURL(for songID: String) throws -> URL {
        try makeURL(
            action: "stream",
            queryItems: [URLQueryItem(name: "id", value: songID)]
        )
    }

    func download(songID: String) async throws -> NavidromeDownload {
        let url = try makeURL(
            action: "download",
            queryItems: [URLQueryItem(name: "id", value: songID)]
        )
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(from: url)
        } catch let error as URLError {
            throw NavidromeError.transport(error.code)
        }
        guard let response = response as? HTTPURLResponse else {
            throw NavidromeError.invalidResponse
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw NavidromeError.httpStatus(response.statusCode)
        }
        guard response.mimeType?.localizedCaseInsensitiveContains("xml") != true,
              response.mimeType?.localizedCaseInsensitiveContains("json") != true else {
            throw NavidromeError.invalidResponse
        }

        let ownedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yorune-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: ownedURL)
        } catch {
            do {
                try FileManager.default.copyItem(at: temporaryURL, to: ownedURL)
                try? FileManager.default.removeItem(at: temporaryURL)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw NavidromeError.invalidResponse
            }
        }

        return NavidromeDownload(
            temporaryURL: ownedURL,
            suggestedFilename: response.suggestedFilename,
            mimeType: response.mimeType
        )
    }

    private func data(from url: URL) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError {
            throw NavidromeError.transport(error.code)
        }
        guard let response = response as? HTTPURLResponse,
              (200 ... 299).contains(response.statusCode) else {
            if let response = response as? HTTPURLResponse {
                throw NavidromeError.httpStatus(response.statusCode)
            }
            throw NavidromeError.invalidResponse
        }
        return data
    }

    private func decode(_ data: Data) throws -> SubsonicEnvelope {
        do {
            return try JSONDecoder().decode(SubsonicEnvelope.self, from: data)
        } catch {
            throw NavidromeError.invalidResponse
        }
    }

    private func artworkURL(for coverArt: String?) throws -> URL? {
        guard let coverArt, !coverArt.isEmpty else { return nil }
        return try makeURL(
            action: "getCoverArt",
            queryItems: [
                URLQueryItem(name: "id", value: coverArt),
                URLQueryItem(name: "size", value: "600")
            ]
        )
    }

    private func makeURL(action: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: configuration.serverURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw NavidromeError.invalidURL
        }

        let basePath = components.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [
            basePath,
            "rest",
            "\(action).view"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "/")

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

    private static func songSort(_ lhs: Song, _ rhs: Song) -> Bool {
        let lhsDisc = lhs.discNumber ?? 1
        let rhsDisc = rhs.discNumber ?? 1
        if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }

        let lhsTrack = lhs.trackNumber ?? .max
        let rhsTrack = rhs.trackNumber ?? .max
        if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }

        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

struct NavidromeDownload: Sendable {
    let temporaryURL: URL
    let suggestedFilename: String?
    let mimeType: String?
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
    let error: SubsonicResponseError?

    enum CodingKeys: String, CodingKey {
        case status
        case albumList = "albumList2"
        case album
        case error
    }
}

private struct SubsonicAlbumList: Decodable {
    let albums: [SubsonicAlbum]?

    enum CodingKeys: String, CodingKey {
        case albums = "album"
    }
}

private struct SubsonicResponseError: Decodable {
    let code: Int?
    let message: String?
}

private struct SubsonicAlbum: Decodable {
    let id: String
    let name: String
    let coverArt: String?
    let played: SubsonicDate?
}

private struct SubsonicDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        date = (try? container.decode(String.self)).flatMap(Self.parse)
    }

    // Navidrome 写出的小数秒位数不定，统一去掉小数秒，秒级精度足够排序使用。
    private static func parse(_ raw: String) -> Date? {
        var value = raw
        if let range = value.range(of: #"\.\d+"#, options: .regularExpression) {
            value.removeSubrange(range)
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

private struct SubsonicAlbumDetail: Decodable {
    let name: String?
    let coverArt: String?
    let songs: [SubsonicSong]?

    enum CodingKeys: String, CodingKey {
        case name
        case coverArt
        case songs = "song"
    }
}

private struct SubsonicSong: Decodable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let coverArt: String?
    let duration: Double?
    let track: Int?
    let discNumber: Int?
}

enum NavidromeError: Error, Equatable, LocalizedError {
    case invalidURL
    case transport(URLError.Code)
    case httpStatus(Int)
    case server(code: Int?, message: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "The server address is invalid.")
        case .transport(.timedOut):
            String(localized: "The connection timed out.")
        case .transport(.notConnectedToInternet),
             .transport(.dataNotAllowed),
             .transport(.internationalRoamingOff):
            String(localized: "Network access is unavailable.")
        case .transport(.cannotConnectToHost),
             .transport(.cannotFindHost),
             .transport(.dnsLookupFailed),
             .transport(.networkConnectionLost):
            String(localized: "Yorune could not reach the server.")
        case .transport(.appTransportSecurityRequiresSecureConnection):
            String(localized: "iOS blocked the insecure server connection.")
        case .transport:
            String(localized: "The network request failed.")
        case .httpStatus(let statusCode):
            String(
                format: String(localized: "The server returned HTTP %lld."),
                Int64(statusCode)
            )
        case .server(let code, let message):
            if code == 40 || code == 50 {
                String(localized: "Navidrome rejected the username or password.")
            } else if let message, !message.isEmpty {
                String(
                    format: String(localized: "Navidrome: %@"),
                    message
                )
            } else {
                String(localized: "Navidrome rejected the request.")
            }
        case .invalidResponse:
            String(localized: "Navidrome returned an invalid response.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .transport(.notConnectedToInternet),
             .transport(.dataNotAllowed),
             .transport(.cannotConnectToHost),
             .transport(.networkConnectionLost):
            String(
                localized: "Check Local Network access for Yorune in iOS Settings, then verify Surge and the server address."
            )
        case .transport(.timedOut):
            String(
                localized: "Check the server address and port, then verify Surge is connected."
            )
        case .invalidURL:
            String(localized: "Enter a complete address beginning with http:// or https://.")
        default:
            nil
        }
    }
}
