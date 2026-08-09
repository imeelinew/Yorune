import SwiftUI

struct AlbumGridView: View {
    @ObservedObject var library: AlbumLibraryStore
    @ObservedObject var playback: PlaybackController
    let openSettings: () -> Void

    @State private var searchText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 20)
    ]

    var body: some View {
        Group {
            switch library.state {
            case .needsConfiguration:
                VStack(spacing: 16) {
                    Text("Connect a server in Settings")
                        .font(.title3)
                    Button("Open Settings", action: openSettings)
                }
            case .loading:
                ProgressView("Loading")
            case .loaded:
                if library.albums.isEmpty {
                    Text("No Albums")
                        .font(.title3)
                } else {
                    albumCollection
                }
            case .failed:
                VStack(spacing: 16) {
                    Text("Unable to Load Albums")
                        .font(.title3)
                    Button("Retry") {
                        Task {
                            await library.reload()
                        }
                    }
                    Button("Open Settings", action: openSettings)
                }
            }
        }
        .navigationTitle("Albums")
    }

    private var albumCollection: some View {
        Group {
            if filteredAlbums.isEmpty {
                Text("No Results")
                    .font(.title3)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(filteredAlbums) { album in
                            NavigationLink(value: album) {
                                AlbumCardView(album: album)
                            }
                            .buttonStyle(.plain)
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
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(
                album: album,
                library: library,
                playback: playback
            )
        }
    }

    private var filteredAlbums: [Album] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return library.albums }
        return library.albums.filter { $0.title.localizedStandardContains(query) }
    }
}

private struct AlbumDetailView: View {
    private enum LoadState {
        case loading
        case loaded([Song])
        case failed
    }

    let album: Album
    @ObservedObject var library: AlbumLibraryStore
    @ObservedObject var playback: PlaybackController

    @State private var state: LoadState = .loading

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
            if songs.isEmpty {
                Text("No Songs")
                    .font(.title3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        albumHeader(songs)

                        Divider()

                        LazyVStack(spacing: 0) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                AlbumTrackRow(
                                    song: song,
                                    index: index,
                                    isCurrent: playback.currentSong?.id == song.id,
                                    isPlaying: playback.isPlaying
                                ) {
                                    playback.play(song, in: songs)
                                }
                                .contextMenu {
                                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                        playback.playNext(song)
                                    }
                                    Button("Add to Queue", systemImage: "text.badge.plus") {
                                        playback.addToQueue(song)
                                    }
                                }

                                if index < songs.count - 1 {
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
        HStack(alignment: .top, spacing: 20) {
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

                if let artist = songs.first?.artist, !artist.isEmpty {
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

    private func albumMetadata(_ songs: [Song]) -> String {
        let totalDuration = songs.reduce(0) { $0 + $1.duration }
        return "\(songs.count) • \(formatDuration(totalDuration))"
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
        state = .loading

        do {
            state = .loaded(try await library.fetchSongs(in: album))
        } catch {
            state = .failed
        }
    }

}

private struct AlbumTrackRow: View {
    let song: Song
    let index: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let play: () -> Void

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

                    if !song.artist.isEmpty {
                        Text(song.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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

private struct AlbumDetailBackground: View {
    let url: URL?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)

            GeometryReader { geometry in
                AlbumArtworkView(url: url, cornerRadius: 0)
                    .frame(width: geometry.size.width, height: min(440, geometry.size.height))
                    .scaleEffect(1.15)
                    .blur(radius: 70)
                    .opacity(colorScheme == .dark ? 0.38 : 0.18)
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
}
