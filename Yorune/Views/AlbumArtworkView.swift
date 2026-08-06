import AppKit
import SwiftUI

struct AlbumArtworkView: View {
    let url: URL?

    @State private var image: NSImage?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        image = nil
        guard let url else { return }

        do {
            let (data, response) = try await Self.session.data(from: url)
            guard let response = response as? HTTPURLResponse,
                  (200 ... 299).contains(response.statusCode) else {
                return
            }
            image = NSImage(data: data)
        } catch {
            image = nil
        }
    }
}
