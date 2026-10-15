import AVFoundation
import CryptoKit
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
        let completionOnly = CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "completion"
        for format in (completionOnly ? [] : ["m4a", "mp3", "flac", "mp3", "m4a", "flac"]) {
            let track = song(format + "-" + UUID().uuidString)
            let start = Date()
            controller.play(track, in: [track])
            let started = await waitUntil(timeout) { (player()?.currentTime().seconds ?? 0) > 0.1 }
            print("START format=\(format) seconds=\(String(format: "%.3f", Date().timeIntervalSince(start))) passed=\(started)")
            guard started else {
                print("PLAYER FAILED", player()?.currentItem?.error as Any, player()?.status as Any, player()?.currentItem?.status as Any, player()?.reasonForWaitingToPlay as Any)
                controller.stopAndClearQueue()
                precondition(timeout >= 35, "Remote audio missed startup deadline")
                continue
            }
            let url = URL(string: "http://127.0.0.1:\(port)/stats?id=\(track.id)")!
            let (data, _) = try await URLSession.shared.data(from: url)
            print("TRANSFER \(String(decoding: data, as: UTF8.self))")
            let stats = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            precondition((stats["sent"] as! Int) < (stats["size"] as! Int), "Entire song transferred before playback")
            controller.pause()
            try await Task.sleep(for: .milliseconds(150))
            let paused = player()!.currentTime().seconds
            try await Task.sleep(for: .milliseconds(600))
            precondition(abs(player()!.currentTime().seconds - paused) < 0.1, "Playback advanced while paused")
            controller.resume()
            let resumed = await waitUntil(8) { player()!.currentTime().seconds > paused + 0.1 }
            if !resumed { print("RESUME FAILED", player()?.currentItem?.error as Any, player()?.reasonForWaitingToPlay as Any, player()?.currentItem?.loadedTimeRanges as Any) }
            precondition(resumed, "Resume failed")
            controller.stopAndClearQueue()
            precondition(!downloads.isDownloaded(track.id), "Partial stream was marked downloaded")
        }
        if CommandLine.arguments.count < 4 || CommandLine.arguments[3] != "baseline" {
            // All audio bytes can arrive before the HTTP task's completion callback.
            // Switching songs in that interval must preserve the completed file.
            let delayed = song("delayed-" + UUID().uuidString)
            controller.play(delayed, in: [delayed])
            var allBytesArrived = false
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let url = URL(string: "http://127.0.0.1:\(port)/stats?id=\(delayed.id)")!
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let stats = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sent = stats["sent"] as? Int, let size = stats["size"] as? Int,
                   sent >= size {
                    allBytesArrived = true
                    print("DELAYED_TRANSFER sent=\(sent) size=\(size)")
                    break
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            precondition(allBytesArrived, "Delayed fixture did not transfer its audio")
            let delayedSaved = await waitUntil(1) { downloads.isDownloaded(delayed.id) }
            precondition(delayedSaved, "Entire audio arrived but was not marked downloaded before HTTP completion")
            controller.stopAndClearQueue()
            let stillSaved = downloads.localURL(for: delayed.id) != nil
            precondition(stillSaved, "Switching songs discarded completed audio")
            print("DELAYED_COMPLETE savedBeforeHTTPFinish=true survivesSwitch=true")
            if completionOnly { return }
            // Full streaming bytes become a persistent, byte-identical offline file.
            for prefix in ["complete-mp3", "complete-m4a", "complete-flac", "norange", "chunked"] {
                let track = song(prefix + "-" + UUID().uuidString)
                controller.play(track, in: [track])
                let saved = await waitUntil(12) { downloads.isDownloaded(track.id) }
                precondition(saved, "Completed stream was not saved: \(prefix)")
                let statsURL = URL(string: "http://127.0.0.1:\(port)/stats?id=\(track.id)")!
                func statistics() async throws -> [String: Any] {
                    let (data, _) = try await URLSession.shared.data(from: statsURL)
                    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
                }
                let before = try await statistics()
                let bytes = try Data(contentsOf: downloads.localURL(for: track.id)!)
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                precondition(hash == before["sha256"] as! String, "Saved audio differs from source")
                precondition(before["downloads"] as! Int == 0, "Streaming triggered a second download")
                precondition(before["sent"] as! Int == before["size"] as! Int, "Completed streaming transferred duplicate bytes")
                let reopened = DownloadStore(configurationStore: store, downloadsRootURL: root)
                precondition(reopened.localURL(for: track.id) != nil, "Saved stream lost after reopening store")
                controller.stopAndClearQueue()
                controller.play(track, in: [track])
                let localStarted = await waitUntil(3) { (player()?.currentTime().seconds ?? 0) > 0.1 }
                precondition(localStarted, "Saved stream cannot play offline")
                let after = try await statistics()
                precondition(before["requests"] as! Int == after["requests"] as! Int, "Replay fetched audio again")
                controller.stopAndClearQueue()
                print("SAVED format=\(prefix) identical=true persistent=true replayRequests=0 sent=\(before["sent"]!) size=\(before["size"]!)")
            }
            // Explicit Download while streaming keeps the same transfer alive after switching away.
            let pinned = song("mp3-pinned-" + UUID().uuidString)
            controller.play(pinned, in: [pinned])
            let pinnedStarted = await waitUntil(12) { (player()?.currentTime().seconds ?? 0) > 0.1 }
            precondition(pinnedStarted)
            downloads.download(pinned)
            controller.stopAndClearQueue()
            let pinnedSaved = await waitUntil(20) { downloads.isDownloaded(pinned.id) }
            precondition(pinnedSaved, "Explicit download did not continue after switching away")
            let (pinData, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats?id=\(pinned.id)")!)
            let pinStats = try JSONSerialization.jsonObject(with: pinData) as! [String: Any]
            precondition(pinStats["downloads"] as! Int == 0, "Explicit download duplicated the stream")
            print("PINNED saved=true downloadRequests=0")
            let seeking = song("seek-" + UUID().uuidString)
            controller.play(seeking, in: [seeking])
            let seekStarted = await waitUntil(5) { (player()?.currentTime().seconds ?? 0) > 0.1 }
            precondition(seekStarted)
            controller.seek(to: 90)
            let jumped = await waitUntil(8) { (player()?.currentTime().seconds ?? 0) >= 90 }
            precondition(jumped, "Seeking into uncached audio failed")
            controller.seek(to: 5)
            let returned = await waitUntil(5) { (player()?.currentTime().seconds ?? 0) >= 5 && (player()?.currentTime().seconds ?? 0) < 10 }
            precondition(returned, "Seeking back into cached audio failed")
            let seekSaved = await waitUntil(20) { downloads.isDownloaded(seeking.id) }
            precondition(seekSaved, "Sparse stream never filled all holes")
            let (seekData, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats?id=\(seeking.id)")!)
            let seekStats = try JSONSerialization.jsonObject(with: seekData) as! [String: Any]
            let seekBytes = try Data(contentsOf: downloads.localURL(for: seeking.id)!)
            precondition(SHA256.hash(data: seekBytes).map { String(format: "%02x", $0) }.joined() == seekStats["sha256"] as! String)
            controller.stopAndClearQueue()
            print("SEEK forward=true backward=true savedIdentical=true")
            let cancelledSave = song("cancel-save-" + UUID().uuidString)
            controller.play(cancelledSave, in: [cancelledSave])
            let cancelStarted = await waitUntil(5) { (player()?.currentTime().seconds ?? 0) > 0.1 }
            precondition(cancelStarted)
            downloads.download(cancelledSave)
            downloads.cancel([cancelledSave.id])
            let cancelPosition = player()!.currentTime().seconds
            let stillPlaying = await waitUntil(8) { player()!.currentTime().seconds > cancelPosition + 0.2 }
            if !stillPlaying { print("CANCEL FAILED", player()?.currentItem?.error as Any, player()?.reasonForWaitingToPlay as Any, player()?.currentItem?.loadedTimeRanges as Any, controller.failure as Any) }
            precondition(stillPlaying, "Cancelling download interrupted playback")
            try await Task.sleep(for: .seconds(12))
            precondition(!downloads.isDownloaded(cancelledSave.id), "Cancelled download was saved anyway")
            controller.stopAndClearQueue()
            print("CANCEL_SAVE playbackContinues=true saved=false")
            let broken = song("truncated-" + UUID().uuidString)
            controller.play(broken, in: [broken])
            try await Task.sleep(for: .seconds(1))
            precondition(!downloads.isDownloaded(broken.id), "Truncated audio was marked downloaded")
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
