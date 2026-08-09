import AppKit
import SwiftUI

struct AlbumArtworkView: View {
    let url: URL?
    let cornerRadius: CGFloat

    @State private var image: NSImage?

    private static let imageCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 500
        return cache
    }()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    init(url: URL?, cornerRadius: CGFloat = 10) {
        self.url = url
        self.cornerRadius = cornerRadius
        _image = State(initialValue: url.flatMap {
            Self.imageCache.object(forKey: $0 as NSURL)
        })
    }

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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url else {
            image = nil
            return
        }
        if let cachedImage = Self.imageCache.object(forKey: url as NSURL) {
            image = cachedImage
            return
        }
        image = nil

        do {
            let (data, response) = try await Self.session.data(from: url)
            guard !Task.isCancelled,
                  self.url == url,
                  let response = response as? HTTPURLResponse,
                  (200 ... 299).contains(response.statusCode) else {
                return
            }
            guard let loadedImage = NSImage(data: data) else { return }
            Self.imageCache.setObject(loadedImage, forKey: url as NSURL)
            image = loadedImage
        } catch {
            return
        }
    }
}
