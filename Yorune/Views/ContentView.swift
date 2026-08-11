import AppKit
import AVKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        LibraryWindowView(
            library: appModel.library,
            downloads: appModel.downloads,
            playback: appModel.playback,
            openSettings: appModel.showSettings
        )
        .background {
            PlaybackKeyboardShortcutMonitor {
                if appModel.playback.currentSong != nil {
                    appModel.playback.togglePlayback()
                }
            }
            .frame(width: 0, height: 0)
        }
        .tint(YoruneStyle.accent)
    }
}

private struct LibraryWindowView: View {
    let library: AlbumLibraryStore
    let downloads: DownloadStore
    let playback: PlaybackController
    let openSettings: () -> Void

    @State private var selection: LibrarySection? = .albums

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationSplitView {
                SidebarView(selection: $selection)
                    .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 220)
            } detail: {
                LibraryDetailView(
                    library: library,
                    downloads: downloads,
                    playback: playback,
                    openSettings: openSettings
                )
            }

            PlaybackQueueHost(playback: playback)
        }
    }
}

private struct PlaybackQueueHost: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        Group {
            if playback.isQueuePresented {
                PlaybackQueuePanel(playback: playback)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                    .padding(.bottom, 76)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: playback.isQueuePresented)
    }
}

private struct LibraryDetailView: View {
    @ObservedObject var library: AlbumLibraryStore
    @ObservedObject var downloads: DownloadStore
    @ObservedObject var playback: PlaybackController
    let openSettings: () -> Void
    @State private var navigationPath: [Album] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            AlbumGridView(
                library: library,
                downloads: downloads,
                playback: playback,
                openSettings: openSettings
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if navigationPath.isEmpty {
                PlaybackBarInset(playback: playback)
            }
        }
        .alert("Unable to Play", isPresented: failurePresented) {
            Button("Retry") {
                playback.retryPlayback()
            }
            Button("OK", role: .cancel) {
                playback.dismissFailure()
            }
        }
        .alert("Unable to Download", isPresented: downloadFailurePresented) {
            Button("OK", role: .cancel) {
                downloads.dismissFailure()
            }
        }
    }

    private var failurePresented: Binding<Bool> {
        Binding(
            get: { playback.failure != nil },
            set: { isPresented in
                if !isPresented {
                    playback.dismissFailure()
                }
            }
        )
    }

    private var downloadFailurePresented: Binding<Bool> {
        Binding(
            get: { downloads.failure != nil },
            set: { isPresented in
                if !isPresented {
                    downloads.dismissFailure()
                }
            }
        )
    }
}

private struct PlaybackBarInset: View {
    @ObservedObject var playback: PlaybackController

    @ViewBuilder
    var body: some View {
        if playback.currentSong != nil {
            PlayerBar(playback: playback)
        }
    }
}

struct PlayerBar: View {
    @ObservedObject var playback: PlaybackController
    @State private var isSeeking = false
    @State private var pendingSeekTime = 0.0
    @State private var isVolumeVisible = false

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                playerContent
                    .glassEffect(.regular.interactive(), in: Capsule())
            } else {
                playerContent
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0),
                    Color(nsColor: .windowBackgroundColor).opacity(0.22)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 44)
            .padding(.bottom, -8)
            .allowsHitTesting(false)
        }
        .zIndex(2)
    }

    private var playerContent: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width <= 700

            HStack(spacing: 10) {
                songInfoSection(isCompact: isCompact)
                    .frame(width: isCompact ? 52 : 200, height: 52)

                progressSection
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)

                playbackOptionsSection
                    .frame(width: 42, height: 52)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }

    private func songInfoSection(isCompact: Bool) -> some View {
        HStack(spacing: 8) {
            AlbumArtworkView(
                url: playback.currentSong?.artworkURL,
                cornerRadius: 6
            )
            .frame(width: 32, height: 32)

            if !isCompact {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playback.currentSong?.title ?? "")
                        .font(.system(size: 13))
                        .lineLimit(1)

                    Text(playback.currentSong?.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 140, height: 29, alignment: .leading)
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var progressSection: some View {
        ZStack(alignment: .top) {
            PlayerProgressLane(
                elapsedTime: displayedElapsedTime,
                duration: playback.duration,
                canSeek: playback.duration > 0,
                isLoading: playback.isBuffering,
                onScrub: { time in
                    pendingSeekTime = time
                    isSeeking = true
                },
                onCommit: { time in
                    pendingSeekTime = time
                    playback.seek(to: time)
                    isSeeking = false
                }
            )
            .padding(.top, 18)
            .zIndex(1)

            progressActionButtons
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressActionButtons: some View {
        HStack(spacing: 6) {
            AirPlayRoutePicker()
                .frame(width: 28, height: 28)
                .disabled(playback.currentSong == nil)

            PlayerBarIconButton(
                action: playback.toggleShuffle,
                isSelected: playback.isShuffling,
                accessibilityLabel: "Shuffle"
            ) {
                Image(systemName: "shuffle")
                    .font(.system(size: 16))
                    .foregroundStyle(playback.isShuffling ? YoruneStyle.accent : Color.primary)
            }

            PlayerBarIconButton(
                action: playback.playPrevious,
                accessibilityLabel: "Previous"
            ) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 13))
            }
            .disabled(!playback.canGoPrevious)

            PlayerBarIconButton(
                action: playback.togglePlayback,
                accessibilityLabel: playback.isPlaying ? "Pause" : "Play"
            ) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(playback.currentSong == nil)

            PlayerBarIconButton(
                action: playback.playNext,
                accessibilityLabel: "Next"
            ) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13))
            }
            .disabled(!playback.canGoNext)

            PlayerBarIconButton(
                action: playback.cycleRepeatMode,
                isSelected: playback.repeatMode != .off,
                accessibilityLabel: "Repeat"
            ) {
                Image(systemName: repeatSymbol)
                    .font(.system(size: 16))
                    .foregroundStyle(
                        playback.repeatMode == .off
                            ? Color.primary
                            : YoruneStyle.accent
                    )
                    .contentTransition(.symbolEffect(.replace))
            }

            PlayerBarIconButton(
                action: {
                    withAnimation(YoruneStyle.quickAnimation) {
                        isVolumeVisible.toggle()
                    }
                },
                accessibilityLabel: "Volume"
            ) {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 15))
                    .contentTransition(.symbolEffect(.replace))
            }
            .popover(isPresented: $isVolumeVisible, arrowEdge: .bottom) {
                PlayerVolumePopover(playback: playback)
            }
        }
    }

    private var playbackOptionsSection: some View {
        HStack {
            PlayerBarIconButton(
                action: playback.toggleQueueInspector,
                isSelected: playback.isQueuePresented,
                accessibilityLabel: "Queue"
            ) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16))
                    .foregroundStyle(
                        playback.isQueuePresented
                            ? YoruneStyle.accent
                            : Color.primary
                    )
            }
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private var displayedElapsedTime: Double {
        isSeeking ? pendingSeekTime : playback.elapsedTime
    }

    private var volumeSymbol: String {
        switch playback.volume {
        case 0:
            "speaker.slash.fill"
        case ..<0.34:
            "speaker.wave.1.fill"
        case ..<0.67:
            "speaker.wave.2.fill"
        default:
            "speaker.wave.3.fill"
        }
    }

    private var repeatSymbol: String {
        playback.repeatMode == .one ? "repeat.1" : "repeat"
    }
}

private struct PlayerProgressLane: View {
    let elapsedTime: Double
    let duration: Double
    let canSeek: Bool
    let isLoading: Bool
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false
    @State private var isHovering = false

    private var fraction: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(elapsedTime / duration, 0), 1))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(formatTime(elapsedTime))
                Spacer(minLength: 8)
                Text("-\(formatTime(max(0, duration - elapsedTime)))")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .frame(height: 12)

            progressBar
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel(Text("Playback Position"))
        .accessibilityValue(
            Text("\(formatTime(elapsedTime)) / \(formatTime(duration))")
        )
        .accessibilityAdjustableAction { direction in
            guard canSeek else { return }
            let step = max(5, duration * 0.02)
            switch direction {
            case .increment:
                let target = min(duration, elapsedTime + step)
                onScrub(target)
                onCommit(target)
            case .decrement:
                let target = max(0, elapsedTime - step)
                onScrub(target)
                onCommit(target)
            @unknown default:
                break
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumbSize: CGFloat = isDragging ? 14 : (isHovering ? 12 : 10)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(height: 4)

                Capsule()
                    .fill(isLoading ? Color.secondary : YoruneStyle.accent)
                    .frame(width: width * fraction, height: 4)

                Circle()
                    .fill(isLoading ? Color.secondary : YoruneStyle.accent)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(
                        x: min(
                            max(0, width * fraction - thumbSize / 2),
                            max(0, width - thumbSize)
                        )
                    )
                    .opacity(canSeek ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard canSeek, width > 0 else { return }
                        isDragging = true
                        onScrub(progressTime(x: value.location.x, width: width))
                    }
                    .onEnded { value in
                        defer { isDragging = false }
                        guard canSeek, width > 0 else { return }
                        let target = progressTime(x: value.location.x, width: width)
                        onScrub(target)
                        onCommit(target)
                    }
            )
            .onHover { hovering in
                isHovering = hovering
            }
        }
        .frame(height: 12)
    }

    private var trackColor: Color {
        let opacity = isHovering || isDragging ? 0.28 : 0.18
        return colorScheme == .dark
            ? .white.opacity(opacity)
            : .black.opacity(opacity)
    }

    private func progressTime(x: CGFloat, width: CGFloat) -> Double {
        let clampedX = min(max(x, 0), width)
        return duration * Double(clampedX / width)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

private struct PlayerBarIconButton<Icon: View>: View {
    let action: () -> Void
    var isSelected = false
    let accessibilityLabel: LocalizedStringKey
    @ViewBuilder let icon: () -> Icon

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(accessibilityLabel)
            } icon: {
                icon()
                    .frame(width: 28, height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(backgroundColor)
                    }
                    .contentShape(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(PlayerBarIconButtonStyle())
        .frame(width: 28, height: 28)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(Text(accessibilityLabel))
        .opacity(isEnabled ? 1 : 0.38)
        .onHover { hovering in
            withAnimation(YoruneStyle.quickAnimation) {
                isHovering = hovering
            }
        }
    }

    private var backgroundColor: Color {
        let baseColor: Color = colorScheme == .dark ? .white : .black
        if isHovering, isEnabled {
            return baseColor.opacity(0.08)
        }
        if isSelected {
            return baseColor.opacity(0.06)
        }
        return .clear
    }
}

private struct PlayerBarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(YoruneStyle.quickAnimation, value: configuration.isPressed)
    }
}

private struct PlayerVolumePopover: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { playback.volume },
                    set: playback.setVolume
                ),
                in: 0 ... 1
            )
            .accessibilityLabel("Volume")

            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 220)
    }
}

private struct AirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.setRoutePickerButtonColor(.labelColor, for: .normal)
        view.setRoutePickerButtonColor(.labelColor, for: .normalHighlighted)
        let accent = NSColor(srgbRed: 1, green: 0, blue: 0.337, alpha: 1)
        view.setRoutePickerButtonColor(accent, for: .active)
        view.setRoutePickerButtonColor(accent, for: .activeHighlighted)
        view.setAccessibilityLabel(String(localized: "AirPlay"))
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

private struct PlaybackKeyboardShortcutMonitor: NSViewRepresentable {
    let performPlayPause: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(performPlayPause: performPlayPause)
    }

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.coordinator = context.coordinator
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {
        context.coordinator.performPlayPause = performPlayPause
    }

    static func dismantleNSView(_ nsView: WindowTrackingView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.coordinator = nil
    }

    final class WindowTrackingView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.window = window
        }
    }

    final class Coordinator {
        weak var window: NSWindow?
        var performPlayPause: () -> Void

        private var monitor: Any?

        init(performPlayPause: @escaping () -> Void) {
            self.performPlayPause = performPlayPause
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .keyUp]
            ) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stop() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            let eventWindow = event.window ?? NSApp.keyWindow
            let firstResponder = eventWindow?.firstResponder ?? window?.firstResponder
            guard eventWindow === window || eventWindow?.parent === window,
                  event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !(firstResponder is NSTextView) else {
                return event
            }
            guard event.type == .keyDown,
                  !event.isARepeat else { return nil }
            performPlayPause()
            return nil
        }

        deinit {
            stop()
        }
    }
}

private struct PlaybackQueuePanel: View {
    @ObservedObject var playback: PlaybackController
    @State private var isEditing = false

    var body: some View {
        Group {
            if isEditing {
                editingPanel
            } else {
                compactPanel
            }
        }
        .animation(YoruneStyle.quickAnimation, value: isEditing)
    }

    @ViewBuilder
    private var compactPanel: some View {
        if #available(macOS 26.0, *) {
            compactContent
                .glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
        } else {
            compactContent
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
        }
    }

    private var compactContent: some View {
        VStack(spacing: 0) {
            compactHeader

            Divider()
                .opacity(0.3)

            queueContent(isEditing: false)
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
    }

    private var editingPanel: some View {
        VStack(spacing: 0) {
            editingHeader

            Divider()
                .opacity(0.3)

            queueContent(isEditing: true)

            Divider()
                .opacity(0.3)

            queueFooter
        }
        .frame(width: 400)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var compactHeader: some View {
        HStack {
            Text("Up Next")
                .font(.headline)

            Spacer()

            if !playback.upcomingSongs.isEmpty {
                Button {
                    playback.clearUpcoming()
                } label: {
                    Text("Clear")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

            Button {
                isEditing = true
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var editingHeader: some View {
        HStack {
            Text("Up Next")
                .font(.headline)

            Spacer()

            Text("\(playback.queue.count) songs")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                isEditing = false
            } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func queueContent(isEditing: Bool) -> some View {
        if playback.queue.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)

                Text("No Queue")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("Play songs from an album to build your queue")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(playback.queue.enumerated()), id: \.element.id) { index, song in
                        queueRow(
                            song,
                            index: index,
                            isEditing: isEditing
                        )
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func queueRow(_ song: Song, index: Int, isEditing: Bool) -> some View {
        let row = PlaybackQueueRow(
            song: song,
            index: index,
            isCurrent: playback.currentSong?.id == song.id,
            isPlaying: playback.isPlaying,
            play: {
                playback.playQueuedSong(song)
            },
            remove: {
                playback.removeFromQueue(song)
            }
        )

        if isEditing, isUpcoming(song) {
            row
                .draggable(song.id)
                .dropDestination(for: String.self) { songIDs, location in
                    guard let songID = songIDs.first else { return false }
                    playback.moveQueuedSong(
                        songID,
                        relativeTo: song.id,
                        placeAfter: location.y > 28
                    )
                    return true
                }
        } else {
            row
        }
    }

    private var queueFooter: some View {
        HStack(spacing: 0) {
            QueueFooterIconButton(
                systemImage: "shuffle",
                accessibilityLabel: "Shuffle",
                isEnabled: !playback.upcomingSongs.isEmpty,
                isSelected: playback.isShuffling
            ) {
                playback.toggleShuffle()
            }

            Spacer()

            QueueFooterIconButton(
                systemImage: "trash",
                accessibilityLabel: "Clear Queue",
                isEnabled: !playback.queue.isEmpty,
                tint: .red
            ) {
                playback.stopAndClearQueue()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func isUpcoming(_ song: Song) -> Bool {
        guard let currentSong = playback.currentSong,
              let currentIndex = playback.queue.firstIndex(where: { $0.id == currentSong.id }),
              let songIndex = playback.queue.firstIndex(where: { $0.id == song.id })
        else { return false }
        return songIndex > currentIndex
    }
}

private struct PlaybackQueueRow: View {
    let song: Song
    let index: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let play: () -> Void
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                leadingIndicator
                    .frame(width: 24)

                AlbumArtworkView(url: song.artworkURL, cornerRadius: 4)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? YoruneStyle.accent : Color.primary)

                    Text(song.artist)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text(formatDuration(song.duration))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(backgroundColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("Play Now", systemImage: "play.fill", action: play)

            if !isCurrent {
                Divider()
                Button(role: .destructive) {
                    remove()
                } label: {
                    Label("Remove from Queue", systemImage: "minus.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if isCurrent {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    isPlaying
                        ? AnyShapeStyle(YoruneStyle.accent)
                        : AnyShapeStyle(.tertiary)
                )
                .symbolEffect(
                    .variableColor.iterative,
                    options: .repeating,
                    isActive: isPlaying
                )
        } else {
            Text("\(index + 1)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private var backgroundColor: Color {
        if isCurrent {
            return YoruneStyle.accent.opacity(0.1)
        }
        if isHovering {
            return Color.primary.opacity(0.05)
        }
        return .clear
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

private struct QueueFooterIconButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    var isEnabled = true
    var isSelected = false
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? YoruneStyle.accent : tint)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .help(Text(accessibilityLabel))
        .accessibilityLabel(Text(accessibilityLabel))
    }
}
