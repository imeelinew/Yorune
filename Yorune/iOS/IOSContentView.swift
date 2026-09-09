import SwiftUI

private enum IOSLibrarySection: Hashable {
    case albums
    case downloads
    case settings
}

struct IOSContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: IOSLibrarySection = .albums
    @State private var isNowPlayingPresented = false

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactContent
            } else {
                regularContent
            }
        }
        .sheet(isPresented: $isNowPlayingPresented) {
            IOSNowPlayingView(playback: appModel.playback)
        }
        .sheet(isPresented: standaloneQueuePresented) {
            IOSQueueView(playback: appModel.playback)
        }
        .onChange(of: appModel.playback.currentSong == nil) { _, isEmpty in
            if isEmpty {
                isNowPlayingPresented = false
            }
        }
        .tint(YoruneStyle.accent)
        .alert("Unable to Play", isPresented: playbackFailurePresented) {
            Button("Retry") {
                appModel.playback.retryPlayback()
            }
            Button("OK", role: .cancel) {
                appModel.playback.dismissFailure()
            }
        }
        .alert("Unable to Download", isPresented: downloadFailurePresented) {
            Button("OK", role: .cancel) {
                appModel.downloads.dismissFailure()
            }
        } message: {
            if let message = appModel.downloads.failure?.message, !message.isEmpty {
                Text(verbatim: message)
            }
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        if appModel.playback.currentSong == nil {
            compactTabView
                .tabBarMinimizeBehavior(.never)
        } else {
            compactTabView
                .tabViewBottomAccessory {
                    PlayerBar(
                        playback: appModel.playback,
                        usesSystemGlassContainer: true,
                        openNowPlaying: { isNowPlayingPresented = true }
                    )
                }
                .tabBarMinimizeBehavior(.never)
        }
    }

    private var compactTabView: some View {
        TabView(selection: $selection) {
            NavigationStack {
                onlineLibrary
            }
            .tabItem {
                Label("Albums", systemImage: "square.stack")
            }
            .tag(IOSLibrarySection.albums)

            NavigationStack {
                downloadedLibrary
            }
            .tabItem {
                Label("Downloaded", systemImage: "arrow.down.circle")
            }
            .tag(IOSLibrarySection.downloads)

            NavigationStack {
                IOSSettingsView(
                    settings: appModel.settings,
                    configurationStore: appModel.configurationStore,
                    library: appModel.library,
                    playback: appModel.playback
                )
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(IOSLibrarySection.settings)
        }
    }

    private var regularContent: some View {
        NavigationSplitView {
            List {
                IOSSidebarButton(
                    title: "Albums",
                    systemImage: "square.stack",
                    isSelected: selection == .albums
                ) {
                    selection = .albums
                }
                IOSSidebarButton(
                    title: "Downloaded",
                    systemImage: "arrow.down.circle",
                    isSelected: selection == .downloads
                ) {
                    selection = .downloads
                }
                IOSSidebarButton(
                    title: "Settings",
                    systemImage: "gearshape",
                    isSelected: selection == .settings
                ) {
                    selection = .settings
                }
            }
            .navigationTitle("Yorune")
        } detail: {
            NavigationStack {
                switch selection {
                case .albums:
                    onlineLibrary
                case .downloads:
                    downloadedLibrary
                case .settings:
                    IOSSettingsView(
                        settings: appModel.settings,
                        configurationStore: appModel.configurationStore,
                        library: appModel.library,
                        playback: appModel.playback
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if appModel.playback.currentSong != nil {
                PlayerBar(
                    playback: appModel.playback,
                    openNowPlaying: { isNowPlayingPresented = true }
                )
            }
        }
    }

    private var onlineLibrary: some View {
        IOSOnlineLibraryView(
            library: appModel.library,
            downloads: appModel.downloads,
            playback: appModel.playback,
            openSettings: { selection = .settings }
        )
    }

    private var downloadedLibrary: some View {
        IOSDownloadedLibraryView(
            downloads: appModel.downloads,
            playback: appModel.playback
        )
    }

    private var playbackFailurePresented: Binding<Bool> {
        Binding(
            get: { appModel.playback.failure != nil },
            set: { if !$0 { appModel.playback.dismissFailure() } }
        )
    }

    private var downloadFailurePresented: Binding<Bool> {
        Binding(
            get: { appModel.downloads.failure != nil },
            set: { if !$0 { appModel.downloads.dismissFailure() } }
        )
    }

    // 正在播放页打开时，队列由它自己的 sheet 呈现；否则从根视图呈现。
    private var standaloneQueuePresented: Binding<Bool> {
        Binding(
            get: { appModel.playback.isQueuePresented && !isNowPlayingPresented },
            set: { isPresented in
                if !isPresented, appModel.playback.isQueuePresented {
                    appModel.playback.toggleQueueInspector()
                }
            }
        )
    }
}

private struct IOSSidebarButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }
}
