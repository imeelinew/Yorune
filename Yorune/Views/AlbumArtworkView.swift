import CryptoKit
import SwiftUI

#if canImport(AppKit)
import AppKit
private typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
#endif

struct AlbumArtworkView: View {
    let url: URL?
    let cornerRadius: CGFloat
    private let cacheKey: String?

    @State private var image: PlatformImage?
    @State private var displayedCacheKey: String?

    private static let imageCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 500
        return cache
    }()

    init(url: URL?, cornerRadius: CGFloat = 10) {
        self.url = url
        self.cornerRadius = cornerRadius
        let cacheKey = url.map(ArtworkCacheKey.value)
        self.cacheKey = cacheKey
        let cachedImage = Self.cachedImage(for: url, cacheKey: cacheKey)
        _image = State(initialValue: cachedImage)
        _displayedCacheKey = State(
            initialValue: cachedImage == nil ? nil : cacheKey
        )
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            if let image {
                swiftUIImage(image)
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
        .task(id: cacheKey) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url, let cacheKey else {
            image = nil
            displayedCacheKey = nil
            return
        }

        if displayedCacheKey == cacheKey, image != nil {
            return
        }
        if let cachedImage = Self.cachedImage(for: url, cacheKey: cacheKey) {
            image = cachedImage
            displayedCacheKey = cacheKey
            return
        }

        if displayedCacheKey != cacheKey {
            image = nil
            displayedCacheKey = nil
        }

        guard let data = await ArtworkCache.shared.data(for: url),
              let loadedImage = PlatformImage(data: data) else { return }

        Self.imageCache.setObject(loadedImage, forKey: cacheKey as NSString)
        guard !Task.isCancelled, self.cacheKey == cacheKey else { return }
        image = loadedImage
        displayedCacheKey = cacheKey
    }

    private static func cachedImage(
        for url: URL?,
        cacheKey: String?
    ) -> PlatformImage? {
        guard let url, let cacheKey else { return nil }
        if let image = imageCache.object(forKey: cacheKey as NSString) {
            return image
        }
        guard let data = ArtworkCache.shared.cachedData(for: url),
              let image = PlatformImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: cacheKey as NSString)
        return image
    }

    private func swiftUIImage(_ image: PlatformImage) -> Image {
#if canImport(AppKit)
        Image(nsImage: image)
#else
        Image(uiImage: image)
#endif
    }
}

/// 专辑详情页顶部的封面色彩晕染背景，macOS 与 iOS 共用。
struct AlbumDetailBackground: View {
    let url: URL?
    var maxHeight: CGFloat = 440
    var lightOpacity: Double = 0.18
    var darkOpacity: Double = 0.38
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            platformBackground

            GeometryReader { geometry in
                AlbumArtworkView(url: url, cornerRadius: 0)
                    .frame(width: geometry.size.width, height: min(maxHeight, geometry.size.height))
                    .scaleEffect(1.15)
                    .blur(radius: 70)
                    .opacity(colorScheme == .dark ? darkOpacity : lightOpacity)
                    .mask {
                        LinearGradient(
                            colors: [.black, .black.opacity(0.55), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var platformBackground: Color {
#if canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(uiColor: .systemBackground)
#endif
    }
}

enum ArtworkCacheKey {
    private static let volatileQueryNames: Set<String> = [
        "c", "f", "s", "t", "u", "v"
    ]

    static func value(for url: URL) -> String {
        if url.isFileURL {
            return "file:\(url.standardizedFileURL.path)"
        }

        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return "remote:\(url.absoluteString)"
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        let stableQueryItems = (components.queryItems ?? [])
            .filter { !volatileQueryNames.contains($0.name.lowercased()) }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return (lhs.value ?? "") < (rhs.value ?? "")
            }
        components.queryItems = stableQueryItems.isEmpty ? nil : stableQueryItems
        return "remote:\(components.string ?? url.absoluteString)"
    }

    static func filename(for cacheKey: String) -> String {
        SHA256.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined() + ".image"
    }
}

final class ArtworkCache {
    static let shared = ArtworkCache()

    private let memoryCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 500
        cache.totalCostLimit = 100 * 1_024 * 1_024
        return cache
    }()

    private let directoryURL: URL
    private let loader = ArtworkDataLoader()

    init(fileManager: FileManager = .default) {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        directoryURL = applicationSupportURL
            .appendingPathComponent("Yorune", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func cachedData(for url: URL) -> Data? {
        if url.isFileURL {
            return try? Data(contentsOf: url)
        }

        let cacheKey = ArtworkCacheKey.value(for: url)
        if let data = memoryCache.object(forKey: cacheKey as NSString) {
            return data as Data
        }

        guard let data = try? Data(contentsOf: cacheURL(for: cacheKey)) else {
            return nil
        }
        memoryCache.setObject(
            data as NSData,
            forKey: cacheKey as NSString,
            cost: data.count
        )
        return data
    }

    func data(for url: URL) async -> Data? {
        if let data = cachedData(for: url) {
            return data
        }
        guard !url.isFileURL else { return nil }

        let cacheKey = ArtworkCacheKey.value(for: url)
        guard let data = await loader.load(
            from: url,
            cacheKey: cacheKey,
            destinationURL: cacheURL(for: cacheKey)
        ) else {
            return nil
        }
        memoryCache.setObject(
            data as NSData,
            forKey: cacheKey as NSString,
            cost: data.count
        )
        return data
    }

    private func cacheURL(for cacheKey: String) -> URL {
        directoryURL.appendingPathComponent(
            ArtworkCacheKey.filename(for: cacheKey)
        )
    }
}

private actor ArtworkDataLoader {
    private let session: URLSession
    private var requests: [String: Task<Data?, Never>] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    func load(
        from url: URL,
        cacheKey: String,
        destinationURL: URL
    ) async -> Data? {
        if let request = requests[cacheKey] {
            return await request.value
        }

        let request = Task<Data?, Never> { [session] in
            do {
                let (data, response) = try await session.data(from: url)
                guard let response = response as? HTTPURLResponse,
                      (200 ... 299).contains(response.statusCode),
                      response.mimeType?.hasPrefix("image/") == true else {
                    return nil
                }
                try data.write(to: destinationURL, options: .atomic)
                return data
            } catch {
                return nil
            }
        }
        requests[cacheKey] = request
        let data = await request.value
        requests[cacheKey] = nil
        return data
    }
}
