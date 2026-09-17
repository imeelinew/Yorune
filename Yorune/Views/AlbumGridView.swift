import AppKit
import SwiftUI

struct AlbumGridView: View {
    @ObservedObject var library: AlbumLibraryStore
    @ObservedObject var downloads: DownloadStore
    @ObservedObject var playback: PlaybackController
    let openSettings: () -> Void

    @State private var searchText = ""
    @State private var isAtTop = true
    @State private var pullDistance: CGFloat = 0
    @State private var refreshRequested = false

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 20, alignment: .top)
    ]

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                Group {
                    switch library.state {
                    case .needsConfiguration:
                        VStack(spacing: 16) {
                            Text("Connect a server in Settings").font(.title3)
                            Button("Open Settings", action: openSettings)
                        }
                    case .initializing, .loading:
                        ProgressView("Loading")
                    case .loaded:
                        if library.albums.isEmpty {
                            Text("No Albums").font(.title3)
                        } else {
                            albumCollection
                        }
                    case .failed:
                        VStack(spacing: 16) {
                            Text("Unable to Load Albums").font(.title3)
                            Button("Retry", action: refresh).disabled(!canRefresh)
                            Button("Open Settings", action: openSettings)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(
                    minHeight: viewport.size.height,
                    alignment: library.state == .loaded && !filteredAlbums.isEmpty ? .top : .center
                )
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .onChange(of: canRefresh) { _, enabled in
                if !enabled { pullDistance = 0 }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y <= -geometry.contentInsets.top + 1
            } action: { _, atTop in
                isAtTop = atTop
            }
            .background {
                TrackpadPullObserver(
                    isEnabled: canRefresh,
                    isAtTop: isAtTop,
                    distance: $pullDistance,
                    refresh: refresh
                )
            }
            .overlay(alignment: .top) {
                if library.isSyncing || refreshRequested || pullDistance > 0 {
                    HStack(spacing: 8) {
                        if library.isSyncing || refreshRequested {
                            ProgressView().controlSize(.small)
                            Text("Syncing Library")
                        } else {
                            Image(systemName: pullDistance >= 80 ? "arrow.up" : "arrow.down")
                            Text(pullDistance >= 80 ? "Release to Refresh" : "Pull to Refresh")
                        }
                    }
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                }
            }
        }
        .navigationTitle("Albums")
        .accessibilityAction(named: Text("Sync Library")) {
            refresh()
        }
    }

    private var canRefresh: Bool {
        library.state != .needsConfiguration && library.state != .initializing
            && library.state != .loading && !library.isSyncing && !refreshRequested
    }

    private func refresh() {
        guard canRefresh else { return }
        refreshRequested = true
        Task {
            await library.reload()
            refreshRequested = false
        }
    }

    private var albumCollection: some View {
        Group {
            if filteredAlbums.isEmpty {
                Text("No Results")
                    .font(.title3)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(sortedAlbums) { album in
                        NavigationLink(value: album) {
                            AlbumCardView(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
            }
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("Search Albums")
        )
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(
                album: album,
                downloads: downloads,
                playback: playback,
                initialSongs: library.cachedSongs(in: album),
                songLoader: { album in
                    try await library.fetchSongs(in: album)
                }
            )
        }
    }

    private var sortedAlbums: [Album] {
        filteredAlbums.sortedByLastPlayed(recentPlays: playback.recentAlbumPlays)
    }

    private var filteredAlbums: [Album] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return library.albums }
        return library.albums.filter {
            $0.title.localizedStandardContains(query)
                || $0.artist.localizedStandardContains(query)
        }
    }
}

/// macOS ScrollView does not provide the iOS refresh-control gesture.
/// Observe (never consume) precise scroll events, excluding inertial scrolling.
private struct TrackpadPullObserver: NSViewRepresentable {
    var isEnabled: Bool
    var isAtTop: Bool
    @Binding var distance: CGFloat
    var refresh: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.configuration = self
        if !isEnabled { view.resetGesture() }
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObserverView: NSView {
        var configuration: TrackpadPullObserver?
        var pull: CGFloat = 0
        private var tracking = false
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.observe(event)
                return event
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            resetGesture()
        }

        func resetGesture() {
            tracking = false
            pull = 0
        }

        private func observe(_ event: NSEvent) {
            guard let configuration else { return }
            guard configuration.isEnabled, event.window === window,
                  !isHiddenOrHasHiddenAncestor, event.hasPreciseScrollingDeltas,
                  event.momentumPhase.isEmpty else { return }

            if event.phase.contains(.began) {
                tracking = visibleRect.contains(convert(event.locationInWindow, from: nil))
                pull = 0
            }
            guard tracking else { return }
            if event.phase.contains(.cancelled) {
                tracking = false
                pull = 0
            } else if event.phase.contains(.ended) {
                let shouldRefresh = pull >= 80 && configuration.isAtTop
                tracking = false
                pull = 0
                configuration.distance = 0
                if shouldRefresh { configuration.refresh() }
                return
            } else if configuration.isAtTop {
                // Count deliberate movement even for short/empty documents,
                // where native rubber-banding may be unavailable.
                pull = min(160, max(0, pull + event.scrollingDeltaY))
            } else {
                pull = 0
            }
            configuration.distance = pull
        }
    }
}

struct DownloadedAlbumGridView: View {
    @ObservedObject var downloads: DownloadStore
    @ObservedObject var playback: PlaybackController

    @State private var searchText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 20, alignment: .top)
    ]

    var body: some View {
        Group {
            if downloads.offlineAlbums.isEmpty {
                Text("No Downloads")
                    .font(.title3)
            } else if filteredAlbums.isEmpty {
                Text("No Results")
                    .font(.title3)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(sortedAlbums) { album in
                            NavigationLink(value: album) {
                                AlbumCardView(album: album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove Downloads", role: .destructive) {
                                    downloads.remove(albumID: album.id)
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("Search Albums")
        )
        .navigationTitle("Downloaded")
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(
                album: album,
                downloads: downloads,
                playback: playback,
                initialSongs: downloads.offlineSongs(in: album.id),
                songLoader: { album in
                    downloads.offlineSongs(in: album.id)
                },
                isOfflineLibrary: true
            )
        }
    }

    private var sortedAlbums: [Album] {
        filteredAlbums.sortedByLastPlayed(recentPlays: playback.recentAlbumPlays)
    }

    private var filteredAlbums: [Album] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return downloads.offlineAlbums }
        return downloads.offlineAlbums.filter {
            $0.title.localizedStandardContains(query)
                || $0.artist.localizedStandardContains(query)
        }
    }
}

private struct AlbumDetailView: View {
    private enum LoadState {
        case loading
        case loaded([Song])
        case failed
    }

    let album: Album
    @ObservedObject var downloads: DownloadStore
    @ObservedObject var playback: PlaybackController
    let songLoader: @MainActor (Album) async throws -> [Song]
    let isOfflineLibrary: Bool

    @State private var state: LoadState

    init(
        album: Album,
        downloads: DownloadStore,
        playback: PlaybackController,
        initialSongs: [Song]?,
        songLoader: @escaping @MainActor (Album) async throws -> [Song],
        isOfflineLibrary: Bool = false
    ) {
        self.album = album
        self.downloads = downloads
        self.playback = playback
        self.songLoader = songLoader
        self.isOfflineLibrary = isOfflineLibrary
        _state = State(initialValue: initialSongs.map(LoadState.loaded) ?? .loading)
    }

    var body: some View {
        trackContent
            .background {
                AlbumDetailBackground(url: album.artworkURL)
                    .ignoresSafeArea()
            }
            .navigationTitle(album.title)
            .toolbarBackgroundVisibility(.hidden, for: .automatic)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if playback.currentSong != nil {
                    PlayerBar(playback: playback)
                }
            }
        .task(id: album.id) {
            await loadSongs()
        }
    }

    @ViewBuilder
    private var trackContent: some View {
        switch state {
        case .loading:
            ProgressView("Loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(songs):
            let visibleSongs = isOfflineLibrary
                ? downloads.offlineSongs(in: album.id)
                : songs
            if visibleSongs.isEmpty {
                Text("No Songs")
                    .font(.title3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let artist = albumArtist(visibleSongs)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        albumHeader(visibleSongs)

                        Divider()

                        LazyVStack(spacing: 0) {
                            ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                                AlbumTrackRow(
                                    song: song,
                                    index: index,
                                    albumArtist: artist,
                                    isCurrent: playback.currentSong?.id == song.id,
                                    isPlaying: playback.isPlaying,
                                    isDownloaded: downloads.isDownloaded(song.id),
                                    isDownloading: downloads.isDownloading(song.id)
                                ) {
                                    playback.play(song, in: visibleSongs)
                                }
                                .contextMenu {
                                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                        playback.playNext(song)
                                    }
                                    Button("Add to Queue", systemImage: "text.badge.plus") {
                                        playback.addToQueue(song)
                                    }

                                    Divider()

                                    if downloads.isDownloading(song.id) {
                                        Button("Cancel Download", systemImage: "xmark.circle") {
                                            downloads.cancel([song.id])
                                        }
                                    } else if downloads.isDownloaded(song.id) {
                                        Button(
                                            "Remove Download",
                                            systemImage: "trash",
                                            role: .destructive
                                        ) {
                                            downloads.remove([song])
                                        }
                                    } else {
                                        Button {
                                            downloads.download(song)
                                        } label: {
                                            Label("Download", systemImage: "arrow.down.circle")
                                        }
                                    }
                                }

                                if index < visibleSongs.count - 1 {
                                    Divider()
                                        .padding(.leading, 40)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 24)
                }
                .contentMargins(.horizontal, 24, for: .scrollContent)
            }
        case .failed:
            VStack(spacing: 16) {
                Text("Unable to Load Album")
                    .font(.title3)
                Button("Retry") {
                    Task {
                        await loadSongs()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func albumHeader(_ songs: [Song]) -> some View {
        let artist = albumArtist(songs)
        return HStack(alignment: .top, spacing: 20) {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: 8)
                .frame(width: 180, height: 180)

            VStack(alignment: .leading, spacing: 8) {
                Text("Album")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(album.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .lineLimit(2)

                if !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(albumMetadata(songs))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                Spacer(minLength: 24)

                headerButtons(songs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func headerButtons(_ songs: [Song]) -> some View {
        ViewThatFits(in: .horizontal) {
            actionButtons(songs, showsTitles: true)
                .fixedSize(horizontal: true, vertical: false)
            actionButtons(songs, showsTitles: false)
        }
    }

    private func actionButtons(_ songs: [Song], showsTitles: Bool) -> some View {
        HStack(spacing: 16) {
            prominentPlayButton(songs, showsTitle: showsTitles)

            Button {
                playAlbumNext(songs)
            } label: {
                actionLabel("Play Next", systemImage: "text.insert", showsTitle: showsTitles)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                songs.forEach(playback.addToQueue)
            } label: {
                actionLabel("Add to Queue", systemImage: "text.append", showsTitle: showsTitles)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            if isOfflineLibrary || songs.allSatisfy({ downloads.isDownloaded($0.id) }) {
                Button {
                    downloads.remove(songs)
                } label: {
                    actionLabel(
                        "Remove Downloads",
                        systemImage: "trash",
                        showsTitle: showsTitles
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(songs.allSatisfy { !downloads.isDownloaded($0.id) })
            } else {
                Button {
                    downloads.download(songs)
                } label: {
                    actionLabel(
                        "Download",
                        systemImage: albumDownloadSymbol(for: songs),
                        showsTitle: showsTitles
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!songs.contains { song in
                    !downloads.isDownloaded(song.id)
                        && !downloads.isDownloading(song.id)
                })
            }
        }
    }

    @ViewBuilder
    private func prominentPlayButton(_ songs: [Song], showsTitle: Bool) -> some View {
        if #available(macOS 26.0, *) {
            Button {
                if let firstSong = songs.first {
                    playback.play(firstSong, in: songs)
                }
            } label: {
                actionLabel("Play", systemImage: "play.fill", showsTitle: showsTitle)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(YoruneStyle.accent)
        } else {
            Button {
                if let firstSong = songs.first {
                    playback.play(firstSong, in: songs)
                }
            } label: {
                actionLabel("Play", systemImage: "play.fill", showsTitle: showsTitle)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(YoruneStyle.accent)
        }
    }

    @ViewBuilder
    private func actionLabel(
        _ title: LocalizedStringKey,
        systemImage: String,
        showsTitle: Bool
    ) -> some View {
        if showsTitle {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
                .accessibilityLabel(Text(title))
        }
    }

    private func playAlbumNext(_ songs: [Song]) {
        guard playback.currentSong != nil else {
            if let firstSong = songs.first {
                playback.play(firstSong, in: songs)
            }
            return
        }
        songs.reversed().forEach(playback.playNext)
    }

    private func albumDownloadSymbol(for songs: [Song]) -> String {
        songs.allSatisfy { downloads.isDownloaded($0.id) }
            ? "checkmark.circle.fill"
            : "arrow.down.circle"
    }

    private func albumArtist(_ songs: [Song]) -> String {
        if !album.artist.isEmpty { return album.artist }
        return songs.first?.artist ?? ""
    }

    private func albumMetadata(_ songs: [Song]) -> String {
        var parts: [String] = []
        if let genre = album.genre, !genre.isEmpty {
            parts.append(genre)
        }
        if let year = album.year, year > 0 {
            parts.append(String(localized: "album.year", defaultValue: "\(year)"))
        }
        let totalDuration = songs.reduce(0) { $0 + $1.duration }
        parts.append("\(songs.count) • \(formatDuration(totalDuration))")
        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes % 60)):\(String(format: "%02d", seconds))"
        }
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    private func loadSongs() async {
        if case .loaded = state {
            // 已有内容时静默刷新，不再退回加载态。
        } else {
            state = .loading
        }

        do {
            let songs = try await songLoader(album)
            downloads.remember(songs)
            state = .loaded(songs)
        } catch {
            if case .loaded = state { return }
            state = .failed
        }
    }

}

private struct AlbumTrackRow: View {
    let song: Song
    let index: Int
    let albumArtist: String
    let isCurrent: Bool
    let isPlaying: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let play: () -> Void

    private var showsArtist: Bool {
        !song.artist.isEmpty && song.artist != albumArtist
    }

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                Group {
                    if isCurrent {
                        Image(systemName: isPlaying ? "waveform" : "pause.fill")
                            .foregroundStyle(YoruneStyle.accent)
                    } else {
                        Text(song.position.isEmpty ? "\(index + 1)" : song.position)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(width: 28, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 14))
                        .foregroundStyle(isCurrent ? YoruneStyle.accent : Color.primary)
                        .lineLimit(1)

                    if showsArtist {
                        Text(song.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Downloaded")
                } else if isDownloading {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 11, height: 11)
                        .accessibilityLabel("Downloading")
                }

                Text(formatDuration(song.duration))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 45, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(AlbumTrackRowButtonStyle())
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

private struct AlbumTrackRowButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isHovering || configuration.isPressed
                            ? Color.primary.opacity(0.06)
                            : Color.clear
                    )
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(YoruneStyle.quickAnimation, value: configuration.isPressed)
            .animation(YoruneStyle.quickAnimation, value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
