import AppKit
import SwiftUI

struct AlbumGridView: View {
    @ObservedObject var library: AlbumLibraryStore
    @ObservedObject var downloads: DownloadStore
    @ObservedObject var playback: PlaybackController
    let openSettings: () -> Void

    @Binding var searchText: String
    let openAlbum: (Album) -> Void
    @State private var isAtTop = true
    @State private var pullDistance: CGFloat = 0
    @State private var refreshRequested = false

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 22, alignment: .top)
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
                    refreshIndicator
                }
            }
            .animation(
                .spring(response: 0.34, dampingFraction: 0.76),
                value: library.isSyncing || refreshRequested || pullDistance > 0
            )
        }
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

    @ViewBuilder
    private var refreshIndicator: some View {
        let indicator = HStack(spacing: 8) {
            if library.isSyncing || refreshRequested {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing Library")
            } else {
                Image(systemName: pullDistance >= 80 ? "arrow.up" : "arrow.down")
                Text(pullDistance >= 80 ? "Release to Refresh" : "Pull to Refresh")
            }
        }
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)

        if #available(macOS 26.0, *) {
            indicator
                .glassEffect(.regular, in: Capsule())
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .scale(scale: 0.82, anchor: .top)))
                .allowsHitTesting(false)
        } else {
            indicator
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .scale(scale: 0.82, anchor: .top)))
                .allowsHitTesting(false)
        }
    }

    private var albumCollection: some View {
        Group {
            if filteredAlbums.isEmpty {
                Text("No Results")
                    .font(.title3)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                    ForEach(sortedAlbums) { album in
                        Button {
                            openAlbum(album)
                        } label: {
                            AlbumCardView(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
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

struct AlbumDetailView: View {

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        albumHeader(visibleSongs)
                            .padding(.horizontal, 8)

                        trackListSection(visibleSongs)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 36)
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

    private func trackListSection(_ visibleSongs: [Song]) -> some View {
        let artist = albumArtist(visibleSongs)
        let currentSongID = playback.currentSong?.id

        return VStack(alignment: .leading, spacing: 16) {
            LazyVStack(spacing: 0) {
                ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                    let isCurrent = currentSongID == song.id
                    let nextSongID = index + 1 < visibleSongs.count ? visibleSongs[index + 1].id : nil
                    let nextIsCurrent = nextSongID != nil && nextSongID == currentSongID

                    AlbumTrackRow(
                        song: song,
                        index: index,
                        albumArtist: artist,
                        isCurrent: isCurrent,
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

                    if nextSongID != nil {
                        AlbumTrackDivider(hidden: isCurrent || nextIsCurrent)
                    }
                }
            }

            albumFooter(visibleSongs)
                .padding(.horizontal, 12)
        }
    }

    private func albumHeader(_ songs: [Song]) -> some View {
        let artist = albumArtist(songs)
        return HStack(alignment: .bottom, spacing: 26) {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: 12)
                .frame(width: 204, height: 204)

            VStack(alignment: .leading, spacing: 6) {
                Text("Album")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(album.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(YoruneStyle.accent)
                        .lineLimit(1)
                        .padding(.top, 1)
                }

                Text(albumMetadata(songs))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                Spacer(minLength: 20)

                headerButtons(songs)
            }
            .frame(maxWidth: .infinity, minHeight: 204, alignment: .leading)
        }
    }

    private func albumFooter(_ songs: [Song]) -> some View {
        let totalMinutes = max(1, Int((songs.reduce(0) { $0 + $1.duration } / 60).rounded()))
        return Text("\(songs.count) songs, \(totalMinutes) minutes")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
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
        HStack(spacing: 10) {
            prominentPlayButton(songs)

            Button {
                playAlbumNext(songs)
            } label: {
                actionLabel("Play Next", systemImage: "text.insert", showsTitle: showsTitles)
            }
            .buttonStyle(MacSecondaryCapsuleButtonStyle())

            Button {
                songs.forEach(playback.addToQueue)
            } label: {
                actionLabel("Add to Queue", systemImage: "text.append", showsTitle: showsTitles)
            }
            .buttonStyle(MacSecondaryCapsuleButtonStyle())

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
                .buttonStyle(MacSecondaryCapsuleButtonStyle())
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
                .buttonStyle(MacSecondaryCapsuleButtonStyle())
                .disabled(!songs.contains { song in
                    !downloads.isDownloaded(song.id)
                        && !downloads.isDownloading(song.id)
                })
            }
        }
    }

    private func prominentPlayButton(_ songs: [Song]) -> some View {
        Button {
            if let firstSong = songs.first {
                playback.play(firstSong, in: songs)
            }
        } label: {
            Image(systemName: "play.fill")
                .accessibilityLabel(Text("Play"))
        }
        .buttonStyle(MacSecondaryCapsuleButtonStyle())
        .help(Text("Play"))
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
        !songs.isEmpty && songs.allSatisfy { downloads.isDownloaded($0.id) }
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
            parts.append(String(localized: "album.year", defaultValue: "\(String(year))"))
        }
        if !songs.isEmpty {
            let totalMinutes = max(1, Int((songs.reduce(0) { $0 + $1.duration } / 60).rounded()))
            parts.append(String(localized: "\(songs.count) songs, \(totalMinutes) minutes"))
        }
        return parts.joined(separator: " · ")
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

private struct AlbumTrackDivider: View {
    let hidden: Bool

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(hidden ? 0 : 0.06))
            .frame(height: 0.5)
            .padding(.leading, 48)
            .padding(.trailing, 14)
    }
}

private struct MacSecondaryCapsuleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 15)
            .frame(height: 34)
            .contentShape(Capsule())

        Group {
            if #available(macOS 26.0, *) {
                label
                    .glassEffect(.regular.interactive(), in: Capsule())
            } else {
                label
                    .background {
                        Capsule()
                            .fill(
                                Color.primary.opacity(
                                    configuration.isPressed
                                        ? (colorScheme == .dark ? 0.20 : 0.13)
                                        : (colorScheme == .dark ? 0.10 : 0.055)
                                )
                            )
                    }
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07),
                                lineWidth: 0.5
                            )
                    }
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
            HStack(spacing: 14) {
                leadingIndicator
                    .frame(width: 24, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 13.5, weight: isCurrent ? .semibold : .regular))
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

                if isDownloading {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                        .accessibilityLabel("Downloading")
                } else if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Downloaded")
                }

                Text(formatDuration(song.duration))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(AlbumTrackRowButtonStyle(isCurrent: isCurrent))
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if isCurrent {
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(YoruneStyle.accent)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
        } else {
            Text(song.position.isEmpty ? "\(index + 1)" : song.position)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

private struct AlbumTrackRowButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    let isCurrent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
                    .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09)
        }
        if isCurrent {
            return YoruneStyle.accent.opacity(colorScheme == .dark ? 0.14 : 0.075)
        }
        return .clear
    }
}
