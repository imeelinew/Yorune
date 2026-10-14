import AVFoundation
import Foundation

// Artwork is deliberately absent from these audio tests.
@MainActor final class ArtworkCache {
    static let shared = ArtworkCache()
    func cachedData(for url: URL) -> Data? { nil }
    func data(for url: URL) async -> Data? { nil }
}

let playbackTestDefaults = UserDefaults(suiteName: "Yorune.StreamingSmoke.\(ProcessInfo.processInfo.processIdentifier)")!

@main struct PlaybackSmoke {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let port = CommandLine.arguments[1]
        let timeout = Double(CommandLine.arguments[2])!
        let store = ServerConfigurationStore(defaults: playbackTestDefaults)
        let configuration = ServerConfiguration(serverURL: "http://127.0.0.1:\(port)", username: "test", password: "test")
        try store.save(configuration)
        precondition(ServerConfigurationStore(defaults: playbackTestDefaults).configuration?.password == "test")
        do {
            try store.save(ServerConfiguration(serverURL: "invalid", username: "test", password: "changed"))
            fatalError("Invalid configuration accepted")
        } catch { precondition(store.configuration?.password == "test") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = DownloadStore(configurationStore: store, downloadsRootURL: root)
        let controller = PlaybackController(configurationStore: store, downloads: downloads)
        func song(_ id: String) -> Song {
            Song(id: id, title: "Test", artist: "Test", albumID: "test", albumTitle: "Test", duration: 120, trackNumber: 1, discNumber: nil, artworkURL: nil)
        }
        func player() -> AVPlayer? {
            Mirror(reflecting: controller).children.first(where: { $0.label == "player" })?.value as? AVPlayer
        }
        func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }
        for format in ["m4a", "mp3", "flac"] {
            let track = song(format + "-" + UUID().uuidString)
            let start = Date()
            controller.play(track, in: [track])
            let started = await waitUntil(timeout) { (player()?.currentTime().seconds ?? 0) > 0.1 }
            print("START format=\(format) seconds=\(String(format: "%.3f", Date().timeIntervalSince(start))) passed=\(started)")
            guard started else {
                controller.stopAndClearQueue()
                precondition(timeout >= 35, "Remote audio missed startup deadline")
                continue
            }
            let url = URL(string: "http://127.0.0.1:\(port)/stats?id=\(track.id)")!
            let (data, _) = try await URLSession.shared.data(from: url)
            print("TRANSFER \(String(decoding: data, as: UTF8.self))")
            let stats = try JSONSerialization.jsonObject(with: data) as! [String: Int]
            precondition(stats["sent"]! < stats["size"]!, "Entire song transferred before playback")
            controller.pause()
            try await Task.sleep(for: .milliseconds(150))
            let paused = player()!.currentTime().seconds
            try await Task.sleep(for: .milliseconds(600))
            precondition(abs(player()!.currentTime().seconds - paused) < 0.1, "Playback advanced while paused")
            controller.resume()
            let resumed = await waitUntil(8) { player()!.currentTime().seconds > paused + 0.1 }
            precondition(resumed, "Resume failed")
            controller.stopAndClearQueue()
        }
        // The server deliberately interrupts delivery after initial audio starts.
        let interrupted = song("stall-" + UUID().uuidString)
        controller.play(interrupted, in: [interrupted])
        let began = await waitUntil(timeout) { (player()?.currentTime().seconds ?? 0) > 0.1 }
        precondition(began, "Stall fixture never started")
        let stalled = await waitUntil(15) { controller.isBuffering }
        precondition(stalled, "Stall fixture did not exhaust the playback buffer")
        let position = player()!.currentTime().seconds
        let recovered = await waitUntil(20) { player()!.currentTime().seconds > position + 0.2 && !controller.isBuffering }
        precondition(recovered, "Playback did not recover automatically")
        print("STALL recovered=true")
        controller.stopAndClearQueue()
        // A cancelled request must never restart playback or replace a newer song.
        let pending = song("m4a-cancel-" + UUID().uuidString)
        controller.play(pending, in: [pending])
        controller.pause()
        try await Task.sleep(for: .seconds(2))
        precondition(!controller.isPlaying && player()?.rate == 0)
        controller.stopAndClearQueue()
        let local = song("local")
        downloads.download(local)
        let downloaded = await waitUntil(10) { downloads.isDownloaded(local.id) }
        precondition(downloaded, "Local fixture download failed")
        controller.play(pending, in: [pending])
        let start = Date()
        controller.play(local, in: [local])
        let localStarted = await waitUntil(3) { (player()?.currentTime().seconds ?? 0) > 0.1 }
        precondition(localStarted && controller.currentSong?.id == "local")
        try await Task.sleep(for: .seconds(1))
        precondition(controller.currentSong?.id == "local")
        print("LOCAL seconds=\(String(format: "%.3f", Date().timeIntervalSince(start) - 1)) passed=true")
        controller.stopAndClearQueue()
        print("DONE configuration/pause/resume/stall/cancellation/local")
    }
}
