import SwiftUI

private enum IOSLibrarySection: Hashable {
    case albums
    case downloads
    case settings
}

struct IOSContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: IOSLibrarySection = .albums

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactContent
            } else {
                regularContent
            }
        }
        .sheet(isPresented: queuePresented) {
            IOSQueueView(playback: appModel.playback)
        }
        .tint(YoruneStyle.accent)
        .alert("Unable to Play", isPresented: playbackFailurePresented) {
            Button("Retry") {
                appModel.playback.retryPlayback()
            }
            Button("OK", role: .cancel) {
                appModel.playback.dismissFailure()
            }
        }
        .alert("Unable to Download", isPresented: downloadFailurePresented) {
            Button("OK", role: .cancel) {
                appModel.downloads.dismissFailure()
            }
        } message: {
            if let message = appModel.downloads.failure?.message, !message.isEmpty {
                Text(verbatim: message)
            }
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        if appModel.playback.currentSong == nil {
            compactTabView
                .tabBarMinimizeBehavior(.never)
        } else {
            compactTabView
                .tabViewBottomAccessory {
                    PlayerBar(
                        playback: appModel.playback,
                        usesSystemGlassContainer: true,
                        openNowPlaying: {}
                    )
                }
                .tabBarMinimizeBehavior(.never)
        }
    }

    private var compactTabView: some View {
        TabView(selection: $selection) {
            NavigationStack {
                onlineLibrary
            }
            .tabItem {
                Label("Albums", systemImage: "square.stack")
            }
            .tag(IOSLibrarySection.albums)

            NavigationStack {
                downloadedLibrary
            }
            .tabItem {
                Label("Downloaded", systemImage: "arrow.down.circle")
            }
            .tag(IOSLibrarySection.downloads)

            NavigationStack {
                IOSSettingsView(
                    settings: appModel.settings,
                    configurationStore: appModel.configurationStore,
                    library: appModel.library,
                    playback: appModel.playback
                )
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(IOSLibrarySection.settings)
        }
    }

    private var regularContent: some View {
        NavigationSplitView {
            List {
                IOSSidebarButton(
                    title: "Albums",
                    systemImage: "square.stack",
                    isSelected: selection == .albums
                ) {
                    selection = .albums
                }
                IOSSidebarButton(
                    title: "Downloaded",
                    systemImage: "arrow.down.circle",
                    isSelected: selection == .downloads
                ) {
                    selection = .downloads
                }
                IOSSidebarButton(
                    title: "Settings",
                    systemImage: "gearshape",
                    isSelected: selection == .settings
                ) {
                    selection = .settings
                }
            }
            .navigationTitle("Yorune")
        } detail: {
            NavigationStack {
                switch selection {
                case .albums:
                    onlineLibrary
                case .downloads:
                    downloadedLibrary
                case .settings:
                    IOSSettingsView(
                        settings: appModel.settings,
                        configurationStore: appModel.configurationStore,
                        library: appModel.library,
                        playback: appModel.playback
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if appModel.playback.currentSong != nil {
                PlayerBar(playback: appModel.playback)
            }
        }
    }

    private var onlineLibrary: some View {
        IOSOnlineLibraryView(
            library: appModel.library,
            downloads: appModel.downloads,
            playback: appModel.playback,
            openSettings: { selection = .settings }
        )
    }

    private var downloadedLibrary: some View {
        IOSDownloadedLibraryView(
            downloads: appModel.downloads,
            playback: appModel.playback
        )
    }

    private var playbackFailurePresented: Binding<Bool> {
        Binding(
            get: { appModel.playback.failure != nil },
            set: { if !$0 { appModel.playback.dismissFailure() } }
        )
    }

    private var downloadFailurePresented: Binding<Bool> {
        Binding(
            get: { appModel.downloads.failure != nil },
            set: { if !$0 { appModel.downloads.dismissFailure() } }
        )
    }

    private var queuePresented: Binding<Bool> {
        Binding(
            get: { appModel.playback.isQueuePresented },
            set: { isPresented in
                if !isPresented, appModel.playback.isQueuePresented {
                    appModel.playback.toggleQueueInspector()
                }
            }
        )
    }
}

private struct IOSSidebarButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }
}

private struct IOSOnlineLibraryView: View {
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
        .toolbar {
            if library.state != .needsConfiguration {
                ToolbarItem(placement: .topBarTrailing) {
                    IOSLibrarySyncButton(library: library)
                }
            }
        }
    }
}

private struct IOSLibrarySyncButton: View {
    @ObservedObject var library: AlbumLibraryStore

    private var isWorking: Bool {
        library.isSyncing || library.state == .loading
    }

    var body: some View {
        Button {
            Task {
                await library.reload()
            }
        } label: {
            ZStack {
                Image(systemName: "arrow.trianglehead.clockwise")
                    .opacity(isWorking ? 0 : 1)
                ProgressView()
                    .controlSize(.small)
                    .opacity(isWorking ? 1 : 0)
            }
            .frame(width: 20, height: 20)
        }
        .accessibilityLabel("Sync Library")
        .disabled(isWorking)
    }
}

private struct IOSDownloadedLibraryView: View {
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

private struct IOSAlbumCollectionView: View {
    let albums: [Album]
    let emptyTitle: LocalizedStringKey
    @ObservedObject var downloads: DownloadStore
    @ObservedObject var playback: PlaybackController
    var canRemoveDownloads = false
    let loadSongs: @MainActor (Album) async throws -> [Song]

    @State private var searchText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 16, alignment: .top)
    ]

    var body: some View {
        Group {
            if albums.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "music.note.list")
            } else if filteredAlbums.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(filteredAlbums) { album in
                            NavigationLink(value: album) {
                                VStack(alignment: .leading, spacing: 8) {
                                    AlbumArtworkView(url: album.artworkURL)
                                        .aspectRatio(1, contentMode: .fit)
                                    Text(album.title)
                                        .font(.headline)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
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
                    .padding()
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

    private var filteredAlbums: [Album] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return albums }
        return albums.filter { $0.title.localizedStandardContains(query) }
    }
}

private struct IOSAlbumDetailView: View {
    private enum LoadState {
        case loading
        case loaded([Song])
        case failed
    }

    let album: Album
    @ObservedObject var downloads: DownloadStore
    @ObservedObject var playback: PlaybackController
    let loadSongs: @MainActor (Album) async throws -> [Song]
    var isOfflineLibrary = false

    @State private var state: LoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading")
            case let .loaded(songs):
                loadedContent(
                    isOfflineLibrary ? downloads.offlineSongs(in: album.id) : songs
                )
            case .failed:
                ContentUnavailableView {
                    Label("Unable to Load Album", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Retry") {
                        Task { await load() }
                    }
                }
            }
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: album.id) {
            await load()
        }
    }

    private func loadedContent(_ songs: [Song]) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                AlbumArtworkView(url: album.artworkURL)
                    .frame(maxWidth: 280)
                    .aspectRatio(1, contentMode: .fit)

                Text(album.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                if let artist = songs.first?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.headline)
                }

                HStack {
                    Button {
                        if let first = songs.first {
                            playback.play(first, in: songs)
                        }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(songs.isEmpty)

                    if isOfflineLibrary || songs.allSatisfy({ downloads.isDownloaded($0.id) }) {
                        Button {
                            downloads.remove(songs)
                        } label: {
                            Label("Remove Downloads", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(songs.allSatisfy { !downloads.isDownloaded($0.id) })
                    } else {
                        Button {
                            downloads.download(songs)
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            songs.isEmpty
                                || songs.allSatisfy {
                                    downloads.isDownloaded($0.id)
                                        || downloads.isDownloading($0.id)
                                }
                        )
                    }
                }

                LazyVStack(spacing: 0) {
                    ForEach(songs) { song in
                        IOSSongRow(
                            song: song,
                            isCurrent: playback.currentSong?.id == song.id,
                            isPlaying: playback.isPlaying,
                            isDownloaded: downloads.isDownloaded(song.id),
                            isDownloading: downloads.isDownloading(song.id)
                        ) {
                            playback.play(song, in: songs)
                        }
                        .contextMenu {
                            Button("Play Next", systemImage: "text.insert") {
                                playback.playNext(song)
                            }
                            Button("Add to Queue", systemImage: "text.append") {
                                playback.addToQueue(song)
                            }
                            if downloads.isDownloading(song.id) {
                                Button("Cancel Download", systemImage: "xmark.circle") {
                                    downloads.cancel([song.id])
                                }
                            } else if downloads.isDownloaded(song.id) {
                                Button("Remove Download", systemImage: "trash", role: .destructive) {
                                    downloads.remove([song])
                                }
                            } else {
                                Button("Download", systemImage: "arrow.down.circle") {
                                    downloads.download(song)
                                }
                            }
                        }

                        Divider()
                    }
                }
            }
            .padding()
        }
    }

    private func load() async {
        state = .loading
        do {
            let songs = try await loadSongs(album)
            downloads.remember(songs)
            state = .loaded(songs)
        } catch {
            state = .failed
        }
    }
}

private struct IOSSongRow: View {
    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if isCurrent {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(YoruneStyle.accent)
                    } else {
                        Text(song.position)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .foregroundStyle(isCurrent ? YoruneStyle.accent : .primary)
                        .lineLimit(1)
                    if !song.artist.isEmpty {
                        Text(song.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isDownloading {
                    ProgressView()
                } else if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.secondary)
                }

                Text(formatTime(song.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

private struct IOSQueueView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var playback: PlaybackController

    var body: some View {
        NavigationStack {
            List {
                if let currentSong = playback.currentSong {
                    Section("Now Playing") {
                        IOSQueueRow(song: currentSong, isCurrent: true) {
                            playback.playQueuedSong(currentSong)
                        }
                    }
                }

                Section("Up Next") {
                    ForEach(playback.upcomingSongs) { song in
                        IOSQueueRow(song: song, isCurrent: false) {
                            playback.playQueuedSong(song)
                        }
                    }
                    .onDelete { offsets in
                        let songs = playback.upcomingSongs
                        offsets.compactMap { songs.indices.contains($0) ? songs[$0] : nil }
                            .forEach(playback.removeFromQueue)
                    }
                    .onMove(perform: playback.moveUpcoming)
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
    }
}

private struct IOSQueueRow: View {
    let song: Song
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                AlbumArtworkView(url: song.artworkURL, cornerRadius: 5)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading) {
                    Text(song.title)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(YoruneStyle.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let totalSeconds = Int(seconds.rounded(.down))
    return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
}
