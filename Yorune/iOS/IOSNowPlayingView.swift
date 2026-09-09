import SwiftUI

struct IOSNowPlayingView: View {
    @ObservedObject var playback: PlaybackController

    @State private var isSeeking = false
    @State private var pendingSeekTime = 0.0

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            artwork
                .frame(maxHeight: .infinity)

            Spacer(minLength: 24)

            VStack(spacing: 28) {
                songInfo
                progress
                transportControls
                volume
                bottomActions
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .presentationDragIndicator(.visible)
        .presentationBackground {
            IOSNowPlayingBackground(url: playback.currentSong?.artworkURL)
        }
        .sheet(isPresented: queuePresented) {
            IOSQueueView(playback: playback)
        }
    }

    // MARK: - Sections

    private var artwork: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width - 48, geometry.size.height)
            AlbumArtworkView(url: playback.currentSong?.artworkURL, cornerRadius: 12)
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 14)
                .scaleEffect(playback.isPlaying ? 1 : 0.82)
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: playback.isPlaying)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var songInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playback.currentSong?.title ?? "")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(playback.currentSong?.artist ?? "")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progress: some View {
        VStack(spacing: 6) {
            IOSProgressSlider(
                fraction: playback.duration > 0 ? displayedElapsedTime / playback.duration : 0,
                isEnabled: playback.duration > 0,
                onScrub: { fraction in
                    pendingSeekTime = fraction * playback.duration
                    isSeeking = true
                },
                onCommit: { fraction in
                    let target = fraction * playback.duration
                    pendingSeekTime = target
                    playback.seek(to: target)
                    isSeeking = false
                }
            )

            HStack {
                Text(formatPlaybackTime(displayedElapsedTime))
                Spacer()
                Text("-\(formatPlaybackTime(max(0, playback.duration - displayedElapsedTime)))")
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Playback Position"))
        .accessibilityValue(
            Text("\(formatPlaybackTime(displayedElapsedTime)) / \(formatPlaybackTime(playback.duration))")
        )
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            Button(action: playback.playPrevious) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30, weight: .medium))
                    .frame(width: 72, height: 72)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IOSTransportButtonStyle())
            .disabled(!playback.canGoPrevious)
            .accessibilityLabel("Previous")

            Spacer()

            ZStack {
                if playback.isBuffering {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Button(action: playback.togglePlayback) {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 42, weight: .medium))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 84, height: 84)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(IOSTransportButtonStyle())
                    .disabled(playback.currentSong == nil)
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                }
            }
            .frame(width: 84, height: 84)

            Spacer()

            Button(action: playback.playNext) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30, weight: .medium))
                    .frame(width: 72, height: 72)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IOSTransportButtonStyle())
            .disabled(!playback.canGoNext)
            .accessibilityLabel("Next")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
    }

    private var volume: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12))
            Slider(
                value: Binding(
                    get: { playback.volume },
                    set: playback.setVolume
                ),
                in: 0 ... 1
            )
            .tint(.white.opacity(0.85))
            .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12))
        }
        .foregroundStyle(.white.opacity(0.6))
    }

    private var bottomActions: some View {
        HStack {
            IOSNowPlayingActionButton(
                systemImage: "shuffle",
                isActive: playback.isShuffling,
                accessibilityLabel: "Shuffle",
                action: playback.toggleShuffle
            )
            Spacer()
            AirPlayRoutePicker()
                .frame(width: 44, height: 44)
                .disabled(playback.currentSong == nil)
            Spacer()
            IOSNowPlayingActionButton(
                systemImage: "list.bullet",
                isActive: playback.isQueuePresented,
                accessibilityLabel: "Queue",
                action: playback.toggleQueueInspector
            )
            Spacer()
            IOSNowPlayingActionButton(
                systemImage: playback.repeatMode == .one ? "repeat.1" : "repeat",
                isActive: playback.repeatMode != .off,
                accessibilityLabel: "Repeat",
                action: playback.cycleRepeatMode
            )
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Helpers

    private var displayedElapsedTime: Double {
        isSeeking ? pendingSeekTime : playback.elapsedTime
    }

    private var queuePresented: Binding<Bool> {
        Binding(
            get: { playback.isQueuePresented },
            set: { isPresented in
                if !isPresented, playback.isQueuePresented {
                    playback.toggleQueueInspector()
                }
            }
        )
    }
}

private struct IOSNowPlayingBackground: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color(red: 0.12, green: 0.12, blue: 0.14)

            GeometryReader { geometry in
                AlbumArtworkView(url: url, cornerRadius: 0)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(1.6)
                    .blur(radius: 80)
                    .saturation(1.3)
            }

            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct IOSProgressSlider: View {
    let fraction: Double
    let isEnabled: Bool
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height: CGFloat = isDragging ? 12 : 7
            let clamped = CGFloat(min(max(fraction, 0), 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(isDragging ? 0.4 : 0.3))
                    .frame(height: height)

                Capsule()
                    .fill(.white.opacity(isDragging ? 1 : 0.85))
                    .frame(width: max(height, width * clamped), height: height)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: isDragging)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled, width > 0 else { return }
                        isDragging = true
                        onScrub(progressFraction(x: value.location.x, width: width))
                    }
                    .onEnded { value in
                        defer { isDragging = false }
                        guard isEnabled, width > 0 else { return }
                        onCommit(progressFraction(x: value.location.x, width: width))
                    }
            )
        }
        .frame(height: 24)
    }

    private func progressFraction(x: CGFloat, width: CGFloat) -> Double {
        Double(min(max(x, 0), width) / width)
    }
}

private struct IOSTransportButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct IOSNowPlayingActionButton: View {
    let systemImage: String
    let isActive: Bool
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isActive ? .white : .white.opacity(0.65))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.22))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(IOSTransportButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

struct IOSQueueView: View {
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

private func formatPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let totalSeconds = Int(seconds.rounded(.down))
    return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
}
