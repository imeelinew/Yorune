import AppKit
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
                    selection: selection,
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
    let selection: LibrarySection?
    let openSettings: () -> Void
    @State private var navigationPath: [Album] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                switch selection {
                case .downloads:
                    DownloadedAlbumGridView(
                        downloads: downloads,
                        playback: playback
                    )
                default:
                    AlbumGridView(
                        library: library,
                        downloads: downloads,
                        playback: playback,
                        openSettings: openSettings
                    )
                }
            }
        }
        .onChange(of: selection) { _, _ in
            navigationPath = []
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
        } message: {
            if let message = downloads.failure?.message, !message.isEmpty {
                Text(verbatim: message)
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
