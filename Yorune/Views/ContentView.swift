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

/// 播放队列以贴靠窗口右缘的浮动玻璃侧边栏呈现：展开时挤压主内容而非覆盖，
/// 可通过播放栏的队列按钮或侧边栏右上角的关闭按钮随时收起。
private struct PlaybackQueueSidebarHost<Content: View>: View {
    @ObservedObject var playback: PlaybackController
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if playback.isQueuePresented {
                PlaybackQueueSidebar(playback: playback)
                    .frame(width: 300)
                    .padding(.top, 6)
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: playback.isQueuePresented)
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

private struct PlaybackQueueSidebar: View {
    @ObservedObject var playback: PlaybackController
    @State private var isHistoryExpanded = false

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        surface
            .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 6)
    }

    @ViewBuilder
    private var surface: some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header

            if playback.queue.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let song = playback.currentSong {
                            sectionTitle("Now Playing")
                            NowPlayingQueueCard(song: song, isPlaying: playback.isPlaying)
                                .padding(.bottom, 14)
                        }

                        if !upcoming.isEmpty {
                            sectionTitle("Up Next", trailing: Text("\(upcoming.count) songs"))
                            ForEach(upcoming) { song in
                                row(song)
                            }
                        }

                        if !history.isEmpty {
                            historyToggle
                                .padding(.top, upcoming.isEmpty ? 0 : 14)
                            if isHistoryExpanded {
                                ForEach(history) { song in
                                    row(song)
                                        .opacity(0.6)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Queue")
                .font(.system(size: 17, weight: .bold))

            Spacer()

            Button {
                playback.toggleQueueInspector()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help(Text("Hide Queue"))
            .accessibilityLabel(Text("Hide Queue"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func sectionTitle(_ title: LocalizedStringKey, trailing: Text? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if let trailing {
                trailing
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var historyToggle: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                isHistoryExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text("Played")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isHistoryExpanded ? 90 : 0))
                Spacer()
                Text("\(history.count) songs")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ song: Song) -> some View {
        QueueSongRow(
            song: song,
            play: { playback.playQueuedSong(song) },
            remove: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    playback.removeFromQueue(song)
                }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Queue")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Play songs from an album to build your queue")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentIndex: Int? {
        guard let currentSong = playback.currentSong else { return nil }
        return playback.queue.firstIndex(where: { $0.id == currentSong.id })
    }

    private var upcoming: [Song] {
        guard let currentIndex else { return playback.queue }
        return Array(playback.queue[(currentIndex + 1)...])
    }

    private var history: [Song] {
        guard let currentIndex else { return [] }
        return Array(playback.queue[..<currentIndex])
    }
}

private struct NowPlayingQueueCard: View {
    let song: Song
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtworkView(url: song.artworkURL, cornerRadius: 8)
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(song.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !song.albumTitle.isEmpty {
                    Text(song.albumTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isPlaying ? AnyShapeStyle(YoruneStyle.accent) : AnyShapeStyle(.tertiary))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isPlaying)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

private struct QueueSongRow: View {
    let song: Song
    let play: () -> Void
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            AlbumArtworkView(url: song.artworkURL, cornerRadius: 5)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(song.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            ZStack(alignment: .trailing) {
                Text(formatDuration(song.duration))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .opacity(isHovering ? 0 : 1)

                Button(action: remove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Remove from Queue"))
                .accessibilityLabel(Text("Remove from Queue"))
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            }
            .frame(minWidth: 32, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contextMenu {
            Button("Play Now", systemImage: "play.fill", action: play)
            Divider()
            Button(role: .destructive, action: remove) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
        }
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
