import Foundation

struct Album: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let artworkURL: URL?
}

struct Song: Identifiable, Sendable, Codable {
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
