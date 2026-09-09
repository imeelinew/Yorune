import AVFoundation
import Combine
import Foundation
import MediaPlayer
import OSLog

#if canImport(AppKit)
import AppKit
private typealias NowPlayingImage = NSImage
#elseif canImport(UIKit)
import UIKit
private typealias NowPlayingImage = UIImage
#endif

private let playbackLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Yorune",
    category: "Playback"
)

struct PlaybackStateSnapshot: Codable, Equatable {
    let serverURL: String
    let username: String
    let queue: [Song]
    let currentIndex: Int
    let elapsedTime: Double

    func restored(for configuration: ServerConfiguration) -> RestoredPlaybackState? {
        guard serverURL == configuration.serverURL,
              username == configuration.username,
              queue.indices.contains(currentIndex) else { return nil }
        let song = queue[currentIndex]
        let duration = song.duration.isFinite ? max(song.duration, 0) : 0
        let elapsed = elapsedTime.isFinite ? max(elapsedTime, 0) : 0
        return RestoredPlaybackState(
            queue: queue,
            currentIndex: currentIndex,
            duration: duration,
            elapsedTime: duration > 0 ? min(elapsed, duration) : 0
        )
    }
}

struct RestoredPlaybackState: Equatable {
    let queue: [Song]
    let currentIndex: Int
    let duration: Double
    let elapsedTime: Double
}

enum PlaybackURLResolver {
    static func resolve(
        localURL: URL?,
        remoteURL: () async throws -> URL
    ) async throws -> URL {
        if let localURL { return localURL }
        return try await remoteURL()
    }
}

@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let configurationStore: ServerConfigurationStore
    let library: AlbumLibraryStore
    let downloads: DownloadStore
    let playback: PlaybackController
#if os(macOS)
    let updateService: UpdateService
#endif

    private var cancellables = Set<AnyCancellable>()

#if os(macOS)
    private lazy var settingsWindowController = YoruneSettingsWindowController(
        settings: settings,
        configurationStore: configurationStore,
        library: library,
        playback: playback,
        updateService: updateService
    )
#endif

    init() {
        let settings = AppSettings()
        let configurationStore = ServerConfigurationStore()
        let downloads = DownloadStore(configurationStore: configurationStore)
        self.settings = settings
        self.configurationStore = configurationStore
        self.library = AlbumLibraryStore(configurationStore: configurationStore)
        self.downloads = downloads
        self.playback = PlaybackController(
            configurationStore: configurationStore,
            downloads: downloads
        )
#if os(macOS)
        self.updateService = UpdateService()
        self.updateService.start()
#endif

        settings.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        playback.$currentSong
            .combineLatest(playback.$queue, playback.$repeatMode)
            .sink { [weak self] _, _, _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        settings.appearance.apply()
    }

    func showSettings() {
#if os(macOS)
        settingsWindowController.show()
#endif
    }
}

@MainActor
final class PlaybackController: ObservableObject {
    enum RepeatMode: Int {
        case off
        case all
        case one
    }

    enum PlaybackFailure: String, Identifiable {
        case unableToPlay

        var id: String { rawValue }
    }

    @Published private(set) var currentSong: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var elapsedTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var volume: Double
    @Published private(set) var isShuffling: Bool
    @Published private(set) var repeatMode: RepeatMode
    @Published private(set) var queue: [Song] = []
    @Published private(set) var isQueuePresented = false
    @Published var failure: PlaybackFailure?

    private let configurationStore: ServerConfigurationStore
    private let downloads: DownloadStore
    private var player: AVPlayer?
    private var currentIndex: Int?
    private var loadingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var playerStateCancellable: AnyCancellable?
    private var itemStateCancellable: AnyCancellable?
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var nowPlayingArtwork: MPMediaItemArtwork?
#if os(iOS)
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var wasPlayingBeforeInterruption = false
#endif
    private var lastNowPlayingSecond = -1
    private var lastPersistedPlaybackSecond = -1
    private var retryAttempt = 0
    private var isRetryScheduled = false
    private var pendingSeekOnReady = 0.0
    private var playbackIntent = false
    private let isMutedForUITesting = ProcessInfo.processInfo.environment["YORUNE_UI_TEST_MUTED"] == "1"

    private enum DefaultsKey {
        static let volume = "playback.volume"
        static let shuffle = "playback.shuffle"
        static let repeatMode = "playback.repeatMode"
        static let state = "playback.state"
    }

    private enum VolumeCurve {
        static let minimumDecibels = -60.0

        static func gain(for level: Double) -> Float {
            guard level > 0 else { return 0 }
            let decibels = minimumDecibels * (1 - min(level, 1))
            return Float(pow(10, decibels / 20))
        }
    }

    /// macOS 使用应用内音量并套用听感曲线；iOS 交给系统音量控制，播放器保持满增益。
    private var playerGain: Float {
        if isMutedForUITesting { return 0 }
#if os(iOS)
        return 1
#else
        return VolumeCurve.gain(for: volume)
#endif
    }

    var canGoPrevious: Bool {
        currentSong != nil
    }

    var canGoNext: Bool {
        guard let currentIndex else { return false }
        return queue.indices.contains(currentIndex + 1) || (repeatMode == .all && queue.count > 1)
    }

    var upcomingSongs: [Song] {
        guard let currentIndex, queue.indices.contains(currentIndex + 1) else { return [] }
        return Array(queue[(currentIndex + 1)...])
    }

    init(
        configurationStore: ServerConfigurationStore,
        downloads: DownloadStore
    ) {
        self.configurationStore = configurationStore
        self.downloads = downloads
        let defaults = UserDefaults.standard
        let savedVolume = defaults.object(forKey: DefaultsKey.volume) as? Double ?? 1
        self.volume = savedVolume.isFinite ? min(max(savedVolume, 0), 1) : 1
        self.isShuffling = defaults.bool(forKey: DefaultsKey.shuffle)
        self.repeatMode = RepeatMode(
            rawValue: defaults.integer(forKey: DefaultsKey.repeatMode)
        ) ?? .off
        restorePlaybackState(from: defaults)
#if os(iOS)
        configureAudioSession()
#endif
        configureRemoteCommands()
        updateRemoteCommandModes()
        updateRemoteCommandAvailability()
        if let currentSong, downloads.localURL(for: currentSong.id) != nil {
            loadCurrentSong(resumeAt: elapsedTime, shouldPlay: false)
        }
    }

    deinit {
        loadingTask?.cancel()
        retryTask?.cancel()
        artworkTask?.cancel()
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
#if os(iOS)
        audioSessionObservers.forEach(NotificationCenter.default.removeObserver)
#endif
    }

    func play(_ song: Song, in songs: [Song]) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else {
            playbackLogger.error("Requested song is missing from the queue")
            return
        }
        playbackLogger.info("Playback requested")
        retryTask?.cancel()
        retryTask = nil
        isRetryScheduled = false
        if isShuffling {
            queue = [song] + songs.filter { $0.id != song.id }.shuffled()
            currentIndex = queue.startIndex
        } else {
            queue = songs
            currentIndex = index
        }
        retryAttempt = 0
        loadCurrentSong(resumeAt: 0)
        updateRemoteCommandAvailability()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        playbackIntent = true
#if os(iOS)
        activateAudioSession()
#endif
        if duration > 0, elapsedTime >= duration {
            player?.seek(to: .zero)
            elapsedTime = 0
            pendingSeekOnReady = 0
        }
        guard let player else {
            if currentSong != nil {
                loadCurrentSong(resumeAt: elapsedTime)
            }
            return
        }
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        playbackIntent = false
        player?.pause()
        isPlaying = false
        isBuffering = false
        updateNowPlayingInfo()
        persistPlaybackState()
    }

    func playPrevious() {
        guard let currentIndex else { return }
        if elapsedTime > 3 {
            player?.seek(to: .zero)
            elapsedTime = 0
            pendingSeekOnReady = 0
            updateNowPlayingInfo()
            persistPlaybackState()
            return
        }

        if currentIndex == queue.startIndex {
            guard repeatMode == .all, queue.count > 1 else {
                player?.seek(to: .zero)
                elapsedTime = 0
                pendingSeekOnReady = 0
                updateNowPlayingInfo()
                persistPlaybackState()
                return
            }
            self.currentIndex = queue.index(before: queue.endIndex)
            loadCurrentSong(resumeAt: 0)
            return
        }

        self.currentIndex = queue.index(before: currentIndex)
        retryAttempt = 0
        loadCurrentSong(resumeAt: 0)
    }

    func playNext() {
        guard let currentIndex else { return }
        if queue.indices.contains(currentIndex + 1) {
            self.currentIndex = queue.index(after: currentIndex)
        } else if repeatMode == .all, queue.count > 1 {
            self.currentIndex = queue.startIndex
        } else {
            return
        }
        retryAttempt = 0
        loadCurrentSong(resumeAt: 0)
    }

    func toggleShuffle() {
        isShuffling.toggle()
        UserDefaults.standard.set(isShuffling, forKey: DefaultsKey.shuffle)
        if isShuffling, let currentIndex, queue.indices.contains(currentIndex + 1) {
            let played = Array(queue[...currentIndex])
            let upcoming = Array(queue[(currentIndex + 1)...]).shuffled()
            queue = played + upcoming
        }
        updateRemoteCommandModes()
        persistPlaybackState()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
        UserDefaults.standard.set(repeatMode.rawValue, forKey: DefaultsKey.repeatMode)
        updateRemoteCommandModes()
        updateRemoteCommandAvailability()
    }

    func seek(to time: Double) {
        let target = min(max(time, 0), duration)
        if let player {
            player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        } else {
            pendingSeekOnReady = target
        }
        elapsedTime = target
        updateNowPlayingInfo()
        persistPlaybackState()
    }

    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = min(max(value, 0), 1)
        player?.volume = playerGain
        UserDefaults.standard.set(volume, forKey: DefaultsKey.volume)
    }

    func playNext(_ song: Song) {
        guard let currentIndex else {
            play(song, in: [song])
            return
        }
        guard song.id != currentSong?.id else { return }
        queue.removeAll { $0.id == song.id }
        guard let currentSong,
              let refreshedIndex = queue.firstIndex(where: { $0.id == currentSong.id }) else {
            queue.insert(song, at: min(currentIndex + 1, queue.endIndex))
            updateRemoteCommandAvailability()
            persistPlaybackState()
            return
        }
        self.currentIndex = refreshedIndex
        queue.insert(song, at: queue.index(after: refreshedIndex))
        updateRemoteCommandAvailability()
        persistPlaybackState()
    }

    func addToQueue(_ song: Song) {
        guard currentSong != nil else {
            play(song, in: [song])
            return
        }
        guard !queue.contains(where: { $0.id == song.id }) else { return }
        queue.append(song)
        updateRemoteCommandAvailability()
        persistPlaybackState()
    }

    func playQueuedSong(_ song: Song) {
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        currentIndex = index
        retryAttempt = 0
        loadCurrentSong(resumeAt: 0)
    }

    func moveQueuedSong(_ songID: String, relativeTo destinationID: String, placeAfter: Bool) {
        guard songID != destinationID,
              let currentIndex,
              let sourceIndex = queue.firstIndex(where: { $0.id == songID }),
              sourceIndex > currentIndex,
              let initialDestinationIndex = queue.firstIndex(where: { $0.id == destinationID }),
              initialDestinationIndex > currentIndex else { return }

        let song = queue.remove(at: sourceIndex)
        guard let destinationIndex = queue.firstIndex(where: { $0.id == destinationID }) else {
            return
        }
        let insertionIndex = placeAfter
            ? queue.index(after: destinationIndex)
            : destinationIndex
        queue.insert(song, at: min(insertionIndex, queue.endIndex))
        updateRemoteCommandAvailability()
        persistPlaybackState()
    }

    func removeFromQueue(_ song: Song) {
        guard song.id != currentSong?.id else { return }
        guard let removedIndex = queue.firstIndex(where: { $0.id == song.id }) else { return }
        queue.remove(at: removedIndex)
        if let currentIndex, removedIndex < currentIndex {
            self.currentIndex = currentIndex - 1
        }
        updateRemoteCommandAvailability()
        persistPlaybackState()
    }

    func clearUpcoming() {
        guard let currentIndex else { return }
        queue = Array(queue[...currentIndex])
        updateRemoteCommandAvailability()
        persistPlaybackState()
    }

    func moveUpcoming(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard let currentIndex, !offsets.isEmpty else { return }
        var upcoming = upcomingSongs
        let movingSongs = offsets.sorted().compactMap { index in
            upcoming.indices.contains(index) ? upcoming[index] : nil
        }
        guard !movingSongs.isEmpty else { return }

        for index in offsets.sorted(by: >) where upcoming.indices.contains(index) {
            upcoming.remove(at: index)
        }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertionIndex = min(
            max(destination - removedBeforeDestination, 0),
            upcoming.endIndex
        )
        upcoming.insert(contentsOf: movingSongs, at: insertionIndex)
        queue = Array(queue[...currentIndex]) + upcoming
        updateRemoteCommandAvailability()
        persistPlaybackState()
    }

    func stopAndClearQueue() {
        loadingTask?.cancel()
        loadingTask = nil
        retryTask?.cancel()
        retryTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        itemStateCancellable = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }

        player?.pause()
        player?.replaceCurrentItem(with: nil)
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
#endif
        currentSong = nil
        currentIndex = nil
        queue = []
        playbackIntent = false
        isPlaying = false
        isBuffering = false
        elapsedTime = 0
        duration = 0
        pendingSeekOnReady = 0
        failure = nil
        retryAttempt = 0
        isRetryScheduled = false
        nowPlayingArtwork = nil
        lastNowPlayingSecond = -1
        lastPersistedPlaybackSecond = -1
        isQueuePresented = false
        UserDefaults.standard.removeObject(forKey: DefaultsKey.state)
        updateRemoteCommandAvailability()
    }

    func toggleQueueInspector() {
        isQueuePresented.toggle()
    }

    func retryPlayback() {
        failure = nil
        retryAttempt = 0
        loadCurrentSong(resumeAt: elapsedTime)
    }

    func dismissFailure() {
        failure = nil
    }

    private func loadCurrentSong(resumeAt time: Double, shouldPlay: Bool = true) {
        loadingTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        isRetryScheduled = false
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            playbackLogger.error("Playback queue position is invalid")
            return
        }
        let queuedSong = queue[currentIndex]
        let song = downloads.offlineSong(for: queuedSong.id) ?? queuedSong
        if song != queuedSong {
            queue[currentIndex] = song
        }
        guard downloads.localURL(for: song.id) != nil
                || configurationStore.configuration != nil else {
            playbackLogger.error("Server configuration is unavailable")
            failure = .unableToPlay
            return
        }

        currentSong = song
        elapsedTime = time
        duration = song.duration
        pendingSeekOnReady = time
        playbackIntent = shouldPlay
        isPlaying = shouldPlay
        isBuffering = shouldPlay
        failure = nil
        lastNowPlayingSecond = -1
        loadNowPlayingArtwork(for: song)
        updateRemoteCommandAvailability()
        updateNowPlayingInfo()
        persistPlaybackState()
        loadingTask = Task { [weak self] in
            guard let self else { return }

            do {
                let url = try await PlaybackURLResolver.resolve(
                    localURL: downloads.localURL(for: song.id)
                ) { [self] in
                    guard let configuration = self.configurationStore.configuration else {
                        throw ServerConfigurationError.invalid
                    }
                    return try await NavidromeClient(configuration: configuration)
                        .streamURL(for: song.id)
                }
                guard !Task.isCancelled else { return }

                let item = AVPlayerItem(url: url)
#if os(iOS)
                activateAudioSession()
#endif
                if let player {
                    player.replaceCurrentItem(with: item)
                } else {
                    let player = AVPlayer(playerItem: item)
                    player.automaticallyWaitsToMinimizeStalling = true
                    self.player = player
                    observePlayer(player)
                }
                player?.volume = playerGain

                observeItem(item)
                if playbackIntent {
                    player?.play()
                } else {
                    player?.pause()
                }
                playbackLogger.info("Playback started")
            } catch {
                guard !Task.isCancelled else { return }
                playbackLogger.error("Playback setup failed: \(String(describing: error), privacy: .public)")
                handlePlaybackFailure()
            }
        }
    }

    private func observePlayer(_ player: AVPlayer) {
        observeTime(player)
        playerStateCancellable = player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.handleTimeControlStatus(status)
                }
            }
    }

    private func observeItem(_ item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if repeatMode == .one {
                    player?.seek(to: .zero)
                    elapsedTime = 0
                    player?.play()
                } else if canGoNext {
                    playNext()
                } else {
                    elapsedTime = duration
                    pause()
                }
            }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackFailure()
            }
        }

        itemStateCancellable = item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak item] status in
                Task { @MainActor [weak self, weak item] in
                    guard let self else { return }
                    switch status {
                    case .readyToPlay:
                        handleItemReady(item)
                    case .failed:
                        handlePlaybackFailure()
                    case .unknown:
                        break
                    @unknown default:
                        break
                    }
                }
            }
    }

    private func observeTime(_ player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite {
                    elapsedTime = max(seconds, 0)
                }

                if let itemDuration = player.currentItem?.duration.seconds,
                   itemDuration.isFinite,
                   itemDuration > 0 {
                    duration = itemDuration
                }

                let nowPlayingSecond = Int(seconds)
                if nowPlayingSecond != lastNowPlayingSecond, nowPlayingSecond.isMultiple(of: 2) {
                    lastNowPlayingSecond = nowPlayingSecond
                    updateNowPlayingInfo()
                }

                let persistedSecond = Int(seconds / 5)
                if persistedSecond != lastPersistedPlaybackSecond {
                    lastPersistedPlaybackSecond = persistedSecond
                    persistPlaybackState()
                }
            }
        }
    }

    private func handleItemReady(_ item: AVPlayerItem?) {
        if let itemDuration = item?.duration.seconds,
           itemDuration.isFinite,
           itemDuration > 0 {
            duration = itemDuration
        }
        if pendingSeekOnReady > 0 {
            seek(to: pendingSeekOnReady)
            pendingSeekOnReady = 0
        }
        isBuffering = false
        retryAttempt = 0
        if playbackIntent {
            player?.play()
        }
        updateNowPlayingInfo()
    }

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .paused:
            isBuffering = false
            if !playbackIntent {
                isPlaying = false
            }
        case .waitingToPlayAtSpecifiedRate:
            isBuffering = playbackIntent
        case .playing:
            isBuffering = false
            isPlaying = true
        @unknown default:
            break
        }
    }

    private func handlePlaybackFailure() {
        isBuffering = false
        guard !isRetryScheduled else { return }
        guard retryAttempt < 1 else {
            playbackIntent = false
            isPlaying = false
            failure = .unableToPlay
            updateNowPlayingInfo()
            return
        }

        retryAttempt += 1
        isRetryScheduled = true
        let resumeTime = elapsedTime
        playbackLogger.info("Retrying playback after a failure")
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            retryTask = nil
            isRetryScheduled = false
            loadCurrentSong(resumeAt: resumeTime, shouldPlay: playbackIntent)
        }
    }

#if os(iOS)
    private func configureAudioSession() {
        configureAudioSessionCategory()
        let session = AVAudioSession.sharedInstance()

        let interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(notification)
            }
        }
        let routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioRouteChange(notification)
            }
        }
        let resetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                configureAudioSessionCategory()
                if currentSong != nil {
                    loadCurrentSong(resumeAt: elapsedTime, shouldPlay: playbackIntent)
                }
            }
        }
        audioSessionObservers = [interruptionObserver, routeObserver, resetObserver]
    }

    private func configureAudioSessionCategory() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: []
            )
        } catch {
            playbackLogger.error(
                "Audio session configuration failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            playbackLogger.error(
                "Audio session activation failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = playbackIntent
            player?.pause()
            isPlaying = false
            isBuffering = false
            updateNowPlayingInfo()
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume) else { return }
            activateAudioSession()
            player?.play()
            isPlaying = true
            playbackIntent = true
            updateNowPlayingInfo()
        @unknown default:
            break
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
              reason == .oldDeviceUnavailable else { return }
        pause()
    }
#endif

    private func loadNowPlayingArtwork(for song: Song) {
        artworkTask?.cancel()
        guard let artworkURL = song.artworkURL else {
            nowPlayingArtwork = nil
            return
        }
        if let data = ArtworkCache.shared.cachedData(for: artworkURL),
           let image = NowPlayingImage(data: data) {
            nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            return
        }

        nowPlayingArtwork = nil
        artworkTask = Task { [weak self] in
            guard let data = await ArtworkCache.shared.data(for: artworkURL),
                  !Task.isCancelled,
                  let image = NowPlayingImage(data: data),
                  let self,
                  currentSong?.id == song.id else { return }
            nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateNowPlayingInfo()
        }
    }

    private func restorePlaybackState(from defaults: UserDefaults) {
        guard let configuration = configurationStore.configuration,
              let data = defaults.data(forKey: DefaultsKey.state),
              let snapshot = try? JSONDecoder().decode(PlaybackStateSnapshot.self, from: data),
              let state = snapshot.restored(for: configuration) else {
            defaults.removeObject(forKey: DefaultsKey.state)
            return
        }

        queue = state.queue
        currentIndex = state.currentIndex
        currentSong = state.queue[state.currentIndex]
        duration = state.duration
        elapsedTime = state.elapsedTime
        pendingSeekOnReady = elapsedTime
        playbackIntent = false
        isPlaying = false
        isBuffering = false
        lastPersistedPlaybackSecond = Int(elapsedTime / 5)
    }

    private func persistPlaybackState() {
        let defaults = UserDefaults.standard
        guard let configuration = configurationStore.configuration,
              let currentIndex,
              queue.indices.contains(currentIndex),
              currentSong != nil else {
            defaults.removeObject(forKey: DefaultsKey.state)
            return
        }

        let state = PlaybackStateSnapshot(
            serverURL: configuration.serverURL,
            username: configuration.username,
            queue: queue,
            currentIndex: currentIndex,
            elapsedTime: elapsedTime.isFinite ? max(elapsedTime, 0) : 0
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: DefaultsKey.state)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        register(center.pauseCommand) { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        register(center.togglePlayPauseCommand) { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        register(center.previousTrackCommand) { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }
        register(center.nextTrackCommand) { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }
        register(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
        register(center.changeShuffleModeCommand) { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                guard let self else { return }
                let shouldShuffle = event.shuffleType != .off
                if self.isShuffling != shouldShuffle {
                    self.toggleShuffle()
                }
            }
            return .success
        }
        register(center.changeRepeatModeCommand) { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                guard let self else { return }
                self.repeatMode = switch event.repeatType {
                case .one: .one
                case .all: .all
                default: .off
                }
                UserDefaults.standard.set(self.repeatMode.rawValue, forKey: DefaultsKey.repeatMode)
                self.updateRemoteCommandModes()
                self.updateRemoteCommandAvailability()
            }
            return .success
        }
    }

    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        let target = command.addTarget(handler: handler)
        remoteCommandTargets.append((command, target))
    }

    private func updateRemoteCommandModes() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = isShuffling ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType = switch repeatMode {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }

    private func updateRemoteCommandAvailability() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = currentSong != nil
        center.pauseCommand.isEnabled = currentSong != nil
        center.togglePlayPauseCommand.isEnabled = currentSong != nil
        center.previousTrackCommand.isEnabled = canGoPrevious
        center.nextTrackCommand.isEnabled = canGoNext
        center.changePlaybackPositionCommand.isEnabled = currentSong != nil && duration > 0
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let currentSong else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentSong.title,
            MPMediaItemPropertyArtist: currentSong.artist,
            MPMediaItemPropertyAlbumTitle: currentSong.albumTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: currentIndex ?? 0,
            MPNowPlayingInfoPropertyExternalContentIdentifier: currentSong.id,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }

        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
