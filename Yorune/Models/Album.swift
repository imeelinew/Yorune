import Foundation

struct Album: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let title: String
    let artworkURL: URL?
    let lastPlayed: Date?
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
    func sortedByLastPlayed() -> [Album] {
        sorted { lhs, rhs in
            switch (lhs.lastPlayed, rhs.lastPlayed) {
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
