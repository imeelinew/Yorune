import Foundation

struct Album: Identifiable, Sendable {
    let id: String
    let title: String
    let artworkURL: URL?
}
