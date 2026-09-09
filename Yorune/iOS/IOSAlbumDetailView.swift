import SwiftUI

struct IOSAlbumDetailView: View {
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
    @State private var isRemoveConfirmationPresented = false

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
            VStack(spacing: 0) {
                header(songs)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 20)

                trackList(songs)

                footer(songs)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Header

    private func header(_ songs: [Song]) -> some View {
        VStack(spacing: 0) {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 280)
                .padding(.horizontal, 44)
                .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)
                .padding(.bottom, 18)

            Text(album.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if !albumArtist(songs).isEmpty {
                Text(albumArtist(songs))
                    .font(.title3)
                    .foregroundStyle(YoruneStyle.accent)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .padding(.top, 2)
            }

            actionButtons(songs)
                .padding(.top, 18)
        }
    }

    private func actionButtons(_ songs: [Song]) -> some View {
        HStack(spacing: 14) {
            Button {
                shufflePlay(songs)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(playback.isShuffling ? YoruneStyle.accent : .primary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(songs.isEmpty)
            .accessibilityLabel("Shuffle")

            Button {
                if let first = songs.first {
                    if playback.isShuffling {
                        playback.toggleShuffle()
                    }
                    playback.play(first, in: songs)
                }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(songs.isEmpty)

            downloadButton(songs)
        }
        .frame(maxWidth: 400)
    }

    @ViewBuilder
    private func downloadButton(_ songs: [Song]) -> some View {
        let allDownloaded = !songs.isEmpty && songs.allSatisfy { downloads.isDownloaded($0.id) }
        let anyDownloading = songs.contains { downloads.isDownloading($0.id) }
        let pendingSongs = songs.filter {
            !downloads.isDownloaded($0.id) && !downloads.isDownloading($0.id)
        }

        Button {
            if allDownloaded || isOfflineLibrary {
                isRemoveConfirmationPresented = true
            } else {
                downloads.download(pendingSongs)
            }
        } label: {
            Group {
                if anyDownloading {
                    ProgressView()
                        .controlSize(.regular)
                } else if allDownloaded || isOfflineLibrary {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(YoruneStyle.accent)
                } else {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(songs.isEmpty || (anyDownloading && pendingSongs.isEmpty))
        .accessibilityLabel(allDownloaded || isOfflineLibrary ? "Remove Downloads" : "Download")
        .confirmationDialog(
            "Remove Downloads",
            isPresented: $isRemoveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove Downloads", role: .destructive) {
                downloads.remove(songs)
            }
        }
    }

    // MARK: - Track List

    private func trackList(_ songs: [Song]) -> some View {
        let artist = albumArtist(songs)
        return LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                IOSSongRow(
                    song: song,
                    index: index,
                    showsArtist: !song.artist.isEmpty && song.artist != artist,
                    isCurrent: playback.currentSong?.id == song.id,
                    isPlaying: playback.isPlaying,
                    isDownloaded: downloads.isDownloaded(song.id),
                    isDownloading: downloads.isDownloading(song.id),
                    play: {
                        playback.play(song, in: songs)
                    },
                    actions: {
                        songActions(song)
                    }
                )

                if index < songs.count - 1 {
                    Divider()
                        .padding(.leading, 56)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func songActions(_ song: Song) -> some View {
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
            Button("Remove Download", systemImage: "trash", role: .destructive) {
                downloads.remove([song])
            }
        } else {
            Button("Download", systemImage: "arrow.down.circle") {
                downloads.download(song)
            }
        }
    }

    private func footer(_ songs: [Song]) -> some View {
        let totalMinutes = Int((songs.reduce(0) { $0 + $1.duration } / 60).rounded())
        return Text("\(songs.count) songs, \(totalMinutes) minutes")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func albumArtist(_ songs: [Song]) -> String {
        if !album.artist.isEmpty { return album.artist }
        return songs.first?.artist ?? ""
    }

    private func shufflePlay(_ songs: [Song]) {
        guard let start = songs.randomElement() else { return }
        if !playback.isShuffling {
            playback.toggleShuffle()
        }
        playback.play(start, in: songs)
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

private struct IOSSongRow<Actions: View>: View {
    let song: Song
    let index: Int
    let showsArtist: Bool
    let isCurrent: Bool
    let isPlaying: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let play: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 0) {
            Button(action: play) {
                HStack(spacing: 12) {
                    Group {
                        if isCurrent {
                            Image(systemName: "waveform")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(YoruneStyle.accent)
                                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                        } else {
                            Text(song.position.isEmpty ? "\(index + 1)" : song.position)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .frame(width: 24, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.body)
                            .foregroundStyle(isCurrent ? YoruneStyle.accent : .primary)
                            .lineLimit(1)

                        if showsArtist {
                            Text(song.artist)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    } else if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Downloaded")
                    }
                }
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
        .contextMenu {
            actions()
        }
    }
}
