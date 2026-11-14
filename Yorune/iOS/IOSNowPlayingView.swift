import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

struct IOSNowPlayingView: View {
    @ObservedObject var playback: PlaybackController

    @State private var isQueueVisible = false

    var body: some View {
        VStack(spacing: 0) {
            upperStage
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 28) {
                progress
                transportControls
                volume
                bottomActions
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: isQueueVisible)
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .presentationDragIndicator(.visible)
        .presentationBackground {
            IOSNowPlayingBackground(url: playback.currentSong?.artworkURL)
        }
    }

    // MARK: - Upper Stage (Morphing Artwork + Song Info + Queue)

    private var upperStage: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let horizontalInset: CGFloat = 28
            let contentWidth = max(0, width - horizontalInset * 2)

            let songInfoHeight: CGFloat = 50
            let bottomSpacing: CGFloat = 24
            let artworkToInfoSpacing: CGFloat = 22
            let topSpacing: CGFloat = 12

            let artworkAreaHeight = max(
                0,
                height - topSpacing - artworkToInfoSpacing - songInfoHeight - bottomSpacing
            )
            let largeArtworkSide = max(80, min(contentWidth - 16, artworkAreaHeight))
            let largeArtworkCenter = CGPoint(
                x: width / 2,
                y: topSpacing + artworkAreaHeight / 2
            )

            let miniArtworkSize: CGFloat = 56
            let miniTop: CGFloat = 12
            let miniArtworkCenter = CGPoint(
                x: horizontalInset + miniArtworkSize / 2,
                y: miniTop + miniArtworkSize / 2
            )

            let currentArtworkSide = isQueueVisible ? miniArtworkSize : largeArtworkSide
            let currentArtworkCenter = isQueueVisible ? miniArtworkCenter : largeArtworkCenter
            let playingScale: CGFloat = isQueueVisible ? 1 : (playback.isPlaying ? 1 : 0.82)

            let currentSongInfoLeading = isQueueVisible
                ? horizontalInset + miniArtworkSize + 14
                : horizontalInset
            let currentSongInfoWidth = max(
                0,
                width - currentSongInfoLeading - horizontalInset
            )
            let currentSongInfoCenterY = isQueueVisible
                ? miniTop + miniArtworkSize / 2
                : height - bottomSpacing - songInfoHeight / 2

            let queueTop = miniTop + miniArtworkSize + 18
            let queueHeight = max(0, height - queueTop - 12)

            ZStack(alignment: .topLeading) {
                // Queue panel springs up physically from below without any fade animation.
                queueListRegion
                    .frame(width: width, height: queueHeight)
                    .offset(y: isQueueVisible ? 0 : queueHeight + 44)
                    .scaleEffect(isQueueVisible ? 1 : 0.9, anchor: .bottom)
                    .frame(width: width, height: queueHeight, alignment: .top)
                    .clipped()
                    .offset(y: queueTop)
                    .allowsHitTesting(isQueueVisible)
                    .accessibilityHidden(!isQueueVisible)

                songInfoView
                    .scaleEffect(isQueueVisible ? 0.88 : 1, anchor: .leading)
                    .frame(
                        width: currentSongInfoWidth,
                        height: songInfoHeight,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isQueueVisible {
                            isQueueVisible = false
                        }
                    }
                    .position(
                        x: currentSongInfoLeading + currentSongInfoWidth / 2,
                        y: currentSongInfoCenterY
                    )

                AlbumArtworkView(
                    url: playback.currentSong?.artworkURL,
                    cornerRadius: isQueueVisible ? 8 : 12
                )
                .frame(width: currentArtworkSide, height: currentArtworkSide)
                .scaleEffect(playingScale)
                .animation(
                    .spring(response: 0.45, dampingFraction: 0.75),
                    value: playback.isPlaying
                )
                .shadow(
                    color: .black.opacity(isQueueVisible ? 0.28 : 0.4),
                    radius: isQueueVisible ? 8 : 24,
                    x: 0,
                    y: isQueueVisible ? 4 : 14
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if isQueueVisible {
                        isQueueVisible = false
                    }
                }
                .position(currentArtworkCenter)
            }
            .frame(width: width, height: height)
        }
    }

    private var songInfoView: some View {
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

    // MARK: - Queue Pane

    private var queueListRegion: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Up Next")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    if let albumTitle = playback.currentSong?.albumTitle, !albumTitle.isEmpty {
                        Text("From \(albumTitle)")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !playback.upcomingSongs.isEmpty {
                    Button("Clear", action: playback.clearUpcoming)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .transition(.scale(scale: 0.8))
                }
            }

            if playback.upcomingSongs.isEmpty {
                Text("No Queue")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale(scale: 0.9))
            } else {
                List {
                    ForEach(playback.upcomingSongs) { song in
                        IOSNowPlayingQueueRow(song: song) {
                            playback.playQueuedSong(song)
                        }
                        .contextMenu {
                            Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) {
                                playback.removeFromQueue(song)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .onMove(perform: playback.moveUpcoming)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
                .environment(\.defaultMinListRowHeight, 44)
                .padding(.horizontal, -8)
                .transition(.scale(scale: 0.96, anchor: .top))
            }
        }
        .padding(.horizontal, 28)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: playback.upcomingSongs.isEmpty)
    }

    private var progress: some View {
        PlaybackProgressReader(progress: playback.progress) { elapsedTime in
            IOSPlaybackProgress(
                songID: playback.currentSong?.id,
                elapsedTime: elapsedTime,
                duration: playback.duration,
                seek: playback.seek
            )
        }
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
                        .transition(.scale(scale: 0.4))
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
                    .transition(.scale(scale: 0.4))
                }
            }
            .frame(width: 84, height: 84)
            .animation(.spring(response: 0.3, dampingFraction: 0.74), value: playback.isBuffering)

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
            IOSSystemVolumeSlider()
                .frame(height: 24)
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
                isActive: isQueueVisible,
                accessibilityLabel: "Queue"
            ) {
                isQueueVisible.toggle()
            }
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

}

private struct IOSNowPlayingQueueRow: View {
    let song: Song
    let action: () -> Void

    @State private var isTapHighlighted = false
    @State private var highlightTask: Task<Void, Never>?

    var body: some View {
        Button {
            triggerTapHighlight()
            action()
        } label: {
            HStack(spacing: 12) {
                AlbumArtworkView(url: song.artworkURL, cornerRadius: 6)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(IOSQueueRowPressStyle(isTapHighlighted: isTapHighlighted))
        .onDisappear {
            highlightTask?.cancel()
            highlightTask = nil
            isTapHighlighted = false
        }
    }

    private func triggerTapHighlight() {
        highlightTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isTapHighlighted = true
        }
        highlightTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                isTapHighlighted = false
            }
        }
    }
}

private struct IOSQueueRowPressStyle: ButtonStyle {
    let isTapHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isActive = configuration.isPressed || isTapHighlighted
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(isActive ? 0.16 : 0))
            }
            .scaleEffect(isActive ? 0.985 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isActive)
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
                    // 栅格化为静态位图，避免队列滚动/动画时逐帧重算大半径模糊。
                    .drawingGroup()
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

/// Keeps 120 Hz drag updates local so the artwork and blurred background are
/// not recomputed for every finger movement.
private struct IOSPlaybackProgress: View {
    let songID: String?
    let elapsedTime: Double
    let duration: Double
    let seek: (Double) -> Void

    @GestureState private var isTouching = false
    @State private var initialFraction: Double?
    @State private var previewFraction: Double?
    @State private var committedTarget: Double?
    @State private var isDragging = false

    private var liveFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsedTime / duration, 0), 1)
    }

    private var displayedFraction: Double {
        previewFraction ?? liveFraction
    }

    private var displayedElapsedTime: Double {
        displayedFraction * duration
    }

    var body: some View {
        VStack(spacing: 6) {
            slider

            HStack {
                Text(formatPlaybackTime(displayedElapsedTime))
                Spacer()
                Text("-\(formatPlaybackTime(max(0, duration - displayedElapsedTime)))")
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Playback Position"))
        .accessibilityValue(
            Text("\(formatPlaybackTime(displayedElapsedTime)) / \(formatPlaybackTime(duration))")
        )
        .onChange(of: songID) { _, _ in
            resetInteraction(clearPreview: true)
        }
        .onChange(of: elapsedTime) { _, newTime in
            guard let committedTarget, abs(newTime - committedTarget) < 1 else { return }
            clearCommittedPreview()
        }
        .onChange(of: isTouching) { _, touching in
            // GestureState resets when the system cancels without onEnded.
            if !touching, initialFraction != nil || isDragging {
                resetInteraction(clearPreview: true)
            }
        }
        .onDisappear {
            resetInteraction(clearPreview: true)
        }
    }

    private var slider: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height: CGFloat = isDragging ? 12 : 7
            let clamped = CGFloat(displayedFraction)

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
                    .updating($isTouching) { _, touching, _ in
                        touching = true
                    }
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        if initialFraction == nil {
                            initialFraction = liveFraction
                        }
                        // Ignore tap jitter, but keep touch-down as the origin.
                        guard isDragging || abs(value.translation.width) >= 3 else { return }
                        isDragging = true
                        previewFraction = progressFraction(
                            translation: value.translation.width,
                            width: width
                        )
                    }
                    .onEnded { value in
                        guard duration > 0, width > 0, isDragging else {
                            resetInteraction(clearPreview: true)
                            return
                        }
                        let fraction = progressFraction(
                            translation: value.translation.width,
                            width: width
                        )
                        let target = fraction * duration
                        previewFraction = fraction
                        committedTarget = target
                        initialFraction = nil
                        isDragging = false
                        seek(target)
                    }
            )
        }
        .frame(height: 24)
    }

    private func progressFraction(translation: CGFloat, width: CGFloat) -> Double {
        min(max((initialFraction ?? liveFraction) + Double(translation / width), 0), 1)
    }

    private func clearCommittedPreview() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            previewFraction = nil
            committedTarget = nil
        }
    }

    private func resetInteraction(clearPreview: Bool) {
        initialFraction = nil
        isDragging = false
        if clearPreview {
            previewFraction = nil
            committedTarget = nil
        }
    }
}

private struct IOSTransportButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.spring(response: 0.24, dampingFraction: 0.68), value: configuration.isPressed)
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
                .symbolEffect(.bounce, value: isActive)
                .scaleEffect(isActive ? 1.06 : 1)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.22))
                        .scaleEffect(isActive ? 1 : 0.001)
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.65), value: isActive)
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

/// 系统音量滑杆：与播放进度条采用相同的「按下记录起点、拖动相对位移 + 轨道加粗」交互，
/// 底层通过 MPVolumeView 与 AVAudioSession 保持与硬件音量键、控制中心实时同步。
struct IOSSystemVolumeSlider: View {
    var tint: Color = .white

    @StateObject private var bridge = IOSSystemVolumeBridge()
    @GestureState private var isTouching = false
    @State private var initialFraction: Double?
    @State private var previewFraction: Double?
    @State private var isDragging = false

    private var displayedFraction: Double {
        previewFraction ?? bridge.volume
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height: CGFloat = isDragging ? 12 : 7
            let clamped = CGFloat(min(max(displayedFraction, 0), 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(isDragging ? 0.4 : 0.3))
                    .frame(height: height)

                Capsule()
                    .fill(tint.opacity(isDragging ? 1 : 0.85))
                    .frame(
                        width: clamped > 0.001 ? max(height, width * clamped) : 0,
                        height: height
                    )
            }
            .frame(height: geometry.size.height)
            .background {
                IOSSystemVolumeBridgeView(bridge: bridge)
                    .frame(width: 1, height: 1)
                    .opacity(0.0001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: isDragging)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTouching) { _, touching, _ in
                        touching = true
                    }
                    .onChanged { value in
                        guard width > 0 else { return }
                        if initialFraction == nil {
                            initialFraction = displayedFraction
                        }
                        // Ignore tap jitter, but keep touch-down as the origin.
                        guard isDragging || abs(value.translation.width) >= 3 else { return }
                        isDragging = true
                        let fraction = volumeFraction(
                            translation: value.translation.width,
                            width: width
                        )
                        previewFraction = fraction
                        bridge.setVolume(fraction)
                    }
                    .onEnded { value in
                        guard width > 0, isDragging else {
                            resetInteraction()
                            return
                        }
                        let fraction = volumeFraction(
                            translation: value.translation.width,
                            width: width
                        )
                        bridge.setVolume(fraction)
                        resetInteraction()
                    }
            )
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel(Text("Volume"))
        .accessibilityValue(Text("\(Int((displayedFraction * 100).rounded()))%"))
        .accessibilityAdjustableAction { direction in
            let step = 0.0625
            switch direction {
            case .increment:
                bridge.setVolume(min(1, displayedFraction + step))
            case .decrement:
                bridge.setVolume(max(0, displayedFraction - step))
            @unknown default:
                break
            }
        }
        .onChange(of: isTouching) { _, touching in
            if !touching, initialFraction != nil || isDragging {
                resetInteraction()
            }
        }
        .onDisappear {
            resetInteraction()
        }
    }

    private func volumeFraction(translation: CGFloat, width: CGFloat) -> Double {
        min(max((initialFraction ?? bridge.volume) + Double(translation / width), 0), 1)
    }

    private func resetInteraction() {
        initialFraction = nil
        previewFraction = nil
        isDragging = false
    }
}

@MainActor
private final class IOSSystemVolumeBridge: ObservableObject {
    @Published private(set) var volume: Double

    private weak var slider: UISlider?
    private var volumeCancellable: AnyCancellable?
    private var sliderCancellable: AnyCancellable?
    private var lastProgrammaticChangeAt: ContinuousClock.Instant?

    init() {
        let initial = Double(AVAudioSession.sharedInstance().outputVolume)
        self.volume = min(max(initial, 0), 1)
        volumeCancellable = AVAudioSession.sharedInstance()
            .publisher(for: \.outputVolume)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newVolume in
                self?.acceptExternalVolume(Double(newVolume))
            }
    }

    func attach(slider: UISlider?) {
        guard self.slider !== slider else { return }
        self.slider = slider
        sliderCancellable = slider?
            .publisher(for: \.value)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                self?.acceptExternalVolume(Double(newValue))
            }
        let sessionVolume = Double(AVAudioSession.sharedInstance().outputVolume)
        volume = min(max(sessionVolume, 0), 1)
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        lastProgrammaticChangeAt = .now
        if let slider {
            slider.setValue(Float(clamped), animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }

    private func acceptExternalVolume(_ newValue: Double) {
        let clamped = min(max(newValue, 0), 1)
        if let lastProgrammaticChangeAt,
           lastProgrammaticChangeAt.duration(to: .now) < .milliseconds(180),
           abs(clamped - volume) > 0.005 {
            return
        }
        if abs(clamped - volume) > 0.001 {
            volume = clamped
        }
    }
}

private struct IOSSystemVolumeBridgeView: UIViewRepresentable {
    let bridge: IOSSystemVolumeBridge

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        let slider = view.subviews.compactMap { $0 as? UISlider }.first
        bridge.attach(slider: slider)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        let slider = uiView.subviews.compactMap { $0 as? UISlider }.first
        bridge.attach(slider: slider)
    }
}
