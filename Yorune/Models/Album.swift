import Foundation

struct Album: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let title: String
    let artist: String
    let genre: String?
    let year: Int?
    let artworkURL: URL?
    let lastPlayed: Date?

    init(
        id: String,
        title: String,
        artist: String,
        genre: String? = nil,
        year: Int? = nil,
        artworkURL: URL?,
        lastPlayed: Date?
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.genre = genre
        self.year = year
        self.artworkURL = artworkURL
        self.lastPlayed = lastPlayed
    }

    // 旧版磁盘缓存没有 artist/genre/year 字段，缺省处理以保持缓存可读。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        genre = try container.decodeIfPresent(String.self, forKey: .genre)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
        lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed)
    }
}

struct Song: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let title: String
    let artist: String
    let albumID: String
    let albumTitle: String
    let duration: Double
    let trackNumber: Int?
    let discNumber: Int?
    let artworkURL: URL?

    var position: String {
        guard let trackNumber else { return "" }
        guard let discNumber, discNumber > 1 else { return String(trackNumber) }
        return "\(discNumber).\(trackNumber)"
    }
}

extension [Album] {
    /// 按最近收听排序。`recentPlays` 是本机记录的专辑最近播放时间，
    /// 与服务器返回的 `lastPlayed` 取较新者，这样本机播放能立即影响排序。
    func sortedByLastPlayed(recentPlays: [String: Date] = [:]) -> [Album] {
        func effectiveDate(_ album: Album) -> Date? {
            switch (album.lastPlayed, recentPlays[album.id]) {
            case let (server?, local?): Swift.max(server, local)
            case let (server?, nil): server
            case let (nil, local?): local
            case (nil, nil): nil
            }
        }

        return sorted { lhs, rhs in
            switch (effectiveDate(lhs), effectiveDate(rhs)) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }
}
