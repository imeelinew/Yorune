import SwiftUI

struct IOSOnlineLibraryView: View {
    @ObservedObject var library: AlbumLibraryStore
    @ObservedObject var downloads: DownloadStore
    @ObservedObject var playback: PlaybackController
    let openSettings: () -> Void

    var body: some View {
        Group {
            switch library.state {
            case .needsConfiguration:
                ContentUnavailableView {
                    Label("Connect a Server", systemImage: "externaldrive.connected.to.line.below")
                } actions: {
                    Button("Open Settings", action: openSettings)
                }
            case .loading:
                ProgressView("Loading")
            case .loaded:
                IOSAlbumCollectionView(
                    albums: library.albums,
                    emptyTitle: "No Albums",
                    downloads: downloads,
                    playback: playback,
                    loadSongs: { album in
                        try await library.fetchSongs(in: album)
                    }
                )
            case .failed:
                ContentUnavailableView {
                    Label("Unable to Load Albums", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Retry") {
                        Task { await library.reload() }
                    }
                    Button("Open Settings", action: openSettings)
                }
            }
        }
        .navigationTitle("Albums")
        .refreshable {
            await library.reload()
        }
    }
}

struct IOSDownloadedLibraryView: View {
    @ObservedObject var downloads: DownloadStore
    @ObservedObject var playback: PlaybackController

    var body: some View {
        IOSAlbumCollectionView(
            albums: downloads.offlineAlbums,
            emptyTitle: "No Downloads",
            downloads: downloads,
            playback: playback,
            canRemoveDownloads: true,
            loadSongs: { album in
                downloads.offlineSongs(in: album.id)
            }
        )
        .navigationTitle("Downloaded")
    }
}

struct IOSAlbumCollectionView: View {
    let albums: [Album]
    let emptyTitle: LocalizedStringKey
    @ObservedObject var downloads: DownloadStore
    @ObservedObject var playback: PlaybackController
    var canRemoveDownloads = false
    let loadSongs: @MainActor (Album) async throws -> [Song]

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var searchText = ""

    private var columns: [GridItem] {
        if horizontalSizeClass == .compact {
            return [
                GridItem(.flexible(), spacing: 16, alignment: .top),
                GridItem(.flexible(), spacing: 16, alignment: .top)
            ]
        }
        return [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16, alignment: .top)]
    }

    var body: some View {
        Group {
            if albums.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "music.note.list")
            } else if filteredAlbums.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(sortedAlbums) { album in
                            NavigationLink(value: album) {
                                IOSAlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if canRemoveDownloads {
                                    Button("Remove Downloads", role: .destructive) {
                                        downloads.remove(albumID: album.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
        .searchable(text: $searchText, prompt: Text("Search Albums"))
        .navigationDestination(for: Album.self) { album in
            IOSAlbumDetailView(
                album: album,
                downloads: downloads,
                playback: playback,
                loadSongs: loadSongs,
                isOfflineLibrary: canRemoveDownloads
            )
        }
    }

    private var sortedAlbums: [Album] {
        filteredAlbums.sortedByLastPlayed()
    }

    private var filteredAlbums: [Album] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return albums }
        return albums.filter {
            $0.title.localizedStandardContains(query)
                || $0.artist.localizedStandardContains(query)
        }
    }
}

private struct IOSAlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: 8)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !album.artist.isEmpty {
                    Text(album.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
    }
}
