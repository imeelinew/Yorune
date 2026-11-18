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
        .containerBackground(.clear, for: .window)
    }
}

private struct LibraryWindowView: View {
    let library: AlbumLibraryStore
    let downloads: DownloadStore
    let playback: PlaybackController
    let openSettings: () -> Void

    var body: some View {
        PlaybackQueueSidebarHost(playback: playback) {
            LibraryDetailView(
                library: library,
                downloads: downloads,
                playback: playback,
                openSettings: openSettings
            )
        }
        .background {
            WindowLiquidGlassBackground()
                .ignoresSafeArea()
        }
    }
}

/// 播放队列以右侧边栏（inspector）的形式贴靠窗口右缘，挤压主内容而非悬浮覆盖，
/// 可通过播放栏的队列按钮随时展开 / 收起，也可拖动分隔线调整宽度。
private struct PlaybackQueueSidebarHost<Content: View>: View {
    @ObservedObject var playback: PlaybackController
    @ViewBuilder let content: Content

    var body: some View {
        content
            .inspector(isPresented: isPresented) {
                PlaybackQueuePanel(playback: playback)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { playback.isQueuePresented },
            set: { newValue in
                if newValue != playback.isQueuePresented {
                    playback.toggleQueueInspector()
                }
            }
        )
    }
}

private struct LibraryDetailView: View {
    @ObservedObject var library: AlbumLibraryStore
    @ObservedObject var downloads: DownloadStore
    @ObservedObject var playback: PlaybackController
    let openSettings: () -> Void
    @State private var selectedAlbum: Album?
    @State private var searchText = ""

    var body: some View {
        ZStack {
            libraryContent
                .opacity(selectedAlbum == nil ? 1 : 0)
                .allowsHitTesting(selectedAlbum == nil)
                .accessibilityHidden(selectedAlbum != nil)

            if let album = selectedAlbum {
                let useOfflineSongs = !library.albums.contains(where: { $0.id == album.id })
                    && downloads.offlineAlbums.contains(where: { $0.id == album.id })
                AlbumDetailView(
                    album: album,
                    downloads: downloads,
                    playback: playback,
                    initialSongs: useOfflineSongs
                        ? downloads.offlineSongs(in: album.id)
                        : library.cachedSongs(in: album),
                    songLoader: { album in
                        if useOfflineSongs {
                            return downloads.offlineSongs(in: album.id)
                        }
                        return try await library.fetchSongs(in: album)
                    },
                    isOfflineLibrary: useOfflineSongs
                )
                .id(album.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if let selectedAlbum {
                // 详情页唯一的封面晕染背景（原先详情视图内部还叠了一层完全相同
                // 的模糊背景，被遮挡却仍然每帧参与渲染）。
                AlbumDetailBackground(
                    url: selectedAlbum.artworkURL,
                    maxHeight: 480,
                    lightOpacity: 0.24,
                    darkOpacity: 0.42
                )
                .ignoresSafeArea()
            }
        }
        .navigationTitle(selectedAlbum?.title ?? String(localized: "Albums"))
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Search Albums"))
        .toolbar {
            if selectedAlbum != nil {
                ToolbarItem(placement: .navigation) {
                    Button { selectedAlbum = nil } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .keyboardShortcut("[", modifiers: .command)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlaybackBarInset(playback: playback, openAlbumFromBar: openCurrentPlayingAlbum)
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

    private var libraryContent: some View {
        AlbumGridView(
            library: library,
            downloads: downloads,
            playback: playback,
            openSettings: openSettings,
            searchText: $searchText,
            openAlbum: { selectedAlbum = $0 }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openCurrentPlayingAlbum() {
        guard let song = playback.currentSong else { return }
        if selectedAlbum?.id == song.albumID {
            return
        }
        let resolvedAlbum = library.albums.first(where: { $0.id == song.albumID })
            ?? downloads.offlineAlbums.first(where: { $0.id == song.albumID })
            ?? Album(
                id: song.albumID,
                title: song.albumTitle,
                artist: song.artist,
                artworkURL: song.artworkURL,
                lastPlayed: nil
            )
        selectedAlbum = resolvedAlbum
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
    let openAlbumFromBar: () -> Void

    @ViewBuilder
    var body: some View {
        if playback.currentSong != nil {
            PlayerBar(
                playback: playback,
                openNowPlaying: openAlbumFromBar
            )
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

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.3)

            queueContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Text("Up Next")
                .font(.headline)

            Spacer()

            if !playback.queue.isEmpty {
                Text("\(playback.queue.count) songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var queueContent: some View {
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
                        PlaybackQueueRow(
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
                    }
                }
                .padding(.vertical, 8)
            }
        }
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

/// 复刻 Kit 主面板的 Liquid Glass + 颜色蒙版背景：
/// 底层使用降低填充层不透明度的 behindWindow 模糊蒙版保证可读性，上层叠加常规 Liquid Glass。
private struct WindowLiquidGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> ContainerView {
        ContainerView()
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {}

    final class ContainerView: NSView {
        private let backdrop = DimmedBackdropView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor

            backdrop.frame = bounds
            backdrop.autoresizingMask = [.width, .height]
            backdrop.material = .headerView
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            addSubview(backdrop)

            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: bounds)
                glass.autoresizingMask = [.width, .height]
                glass.style = .regular
                glass.cornerRadius = 0
                addSubview(glass)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        }
    }

    private final class DimmedBackdropView: NSVisualEffectView {
        override func updateLayer() {
            super.updateLayer()
            for variant in layer?.sublayers ?? [] {
                for sublayer in variant.sublayers ?? [] where sublayer.name == "fill" {
                    sublayer.opacity = 0.38
                }
            }
        }
    }
}
