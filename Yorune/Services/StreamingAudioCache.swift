import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// One sparse file serves AVPlayer and becomes an offline download once every byte exists.
/// All network callbacks, file access and resource-loader requests run on `queue`.
final class StreamingAudioCache: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let asset: AVURLAsset
    private let sourceURL: URL
    private let fileURL: URL
    private let file: FileHandle
    private let queue = DispatchQueue(label: "Yorune.StreamingAudioCache")
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var requests: [AVAssetResourceLoadingRequest] = []
    private var ranges: [Range<Int64>] = []
    private var length: Int64?
    private var mimeType: String?
    private var filename: String?
    private var writeOffset: Int64 = 0
    private var requestEnd: Int64 = 0
    private var requestedStart: Int64 = 0
    private var receivesFullResponse = false
    private var playbackReleased = false
    private var keepDownloading = false
    private var validator: String?
    private var stopped = false
    private var terminalError: Error?
    private var reportedCompletion = false
    private let completion: (Result<NavidromeDownload, Error>) -> Void

    init(url: URL, completion: @escaping (Result<NavidromeDownload, Error>) -> Void) throws {
        sourceURL = url
        self.completion = completion
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("yorune-stream-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        file = try FileHandle(forUpdating: fileURL)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = "yorune-audio"
        asset = AVURLAsset(url: components.url!)
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func retainForDownload() {
        queue.async { self.keepDownloading = true }
    }

    func releasePlayback() {
        queue.async {
            self.playbackReleased = true
            if !self.keepDownloading || self.reportedCompletion { self.stop() }
        }
    }

    /// Cancelling/removing a download must not interrupt the song currently playing.
    func discardDownload() {
        queue.async {
            self.keepDownloading = false
            self.report(.failure(URLError(.cancelled)))
            if self.playbackReleased { self.stop() }
        }
    }

    func cancel() {
        queue.async { self.stop() }
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        session.invalidateAndCancel()
        task = nil
        requests.forEach { $0.finishLoading(with: URLError(.cancelled)) }
        requests.removeAll()
        try? file.close()
        try? FileManager.default.removeItem(at: fileURL)
        report(.failure(URLError(.cancelled)))
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard !stopped else {
            request.finishLoading(with: URLError(.cancelled))
            return true
        }
        requests.append(request)
        serveRequests()
        fetchNextRange()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        requests.removeAll { $0 === request }
    }

    /// Prefer the player's missing bytes (including MP4 tail metadata), then fill remaining holes.
    private func nextOffset() -> Int64? {
        for request in requests.reversed() {
            guard let data = request.dataRequest else { continue }
            let offset = max(data.requestedOffset, data.currentOffset)
            if length == nil || offset < length! { return offset }
        }
        var offset: Int64 = 0
        for range in ranges {
            if range.lowerBound > offset { break }
            offset = max(offset, range.upperBound)
        }
        return length == nil || offset < length! ? offset : nil
    }

    private func fetchNextRange() {
        guard !stopped, terminalError == nil, let offset = nextOffset() else { return }
        // A seek can interrupt a background fill. Received bytes remain in the sparse file.
        if let task {
            if !receivesFullResponse, offset < writeOffset || offset >= requestEnd { task.cancel() }
            return
        }
        // Keep each range small so AVPlayer can finish pending reads promptly on slow links.
        var end = offset + 64 * 1024
        if let length { end = min(end, length) }
        if let next = ranges.first(where: { $0.lowerBound > offset }) { end = min(end, next.lowerBound) }
        guard end > offset else { return }
        var request = URLRequest(url: sourceURL)
        request.setValue("bytes=\(offset)-\(end - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        receivesFullResponse = false
        requestedStart = offset
        writeOffset = offset
        requestEnd = end
        task = session.dataTask(with: request)
        task?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !stopped, let response = response as? HTTPURLResponse,
              [200, 206].contains(response.statusCode),
              response.mimeType?.localizedCaseInsensitiveContains("xml") != true,
              response.mimeType?.localizedCaseInsensitiveContains("json") != true else {
            fail(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        let responseValidator = response.value(forHTTPHeaderField: "ETag")
            ?? response.value(forHTTPHeaderField: "Last-Modified")
        if let validator, responseValidator != validator {
            fail(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        validator = responseValidator
        if response.statusCode == 206 {
            let header = response.value(forHTTPHeaderField: "Content-Range") ?? ""
            let parts = header.replacingOccurrences(of: "bytes ", with: "").split(separator: "/")
            let bounds = parts.first?.split(separator: "-") ?? []
            guard parts.count == 2, bounds.count == 2,
                  let start = Int64(bounds[0]), let end = Int64(bounds[1]),
                  let total = Int64(parts[1]), start == requestedStart,
                  end >= start, end < total, end + 1 <= requestEnd,
                  length == nil || length == total else {
                fail(URLError(.badServerResponse))
                completionHandler(.cancel)
                return
            }
            length = total
            requestEnd = end + 1
        } else {
            // Servers without range support still use one progressive full-file response.
            receivesFullResponse = true
            writeOffset = 0
            length = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            requestEnd = length ?? Int64.max
        }
        mimeType = response.mimeType
        filename = response.suggestedFilename
        serveRequests()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped, terminalError == nil else { return }
        do {
            guard Int64(data.count) <= requestEnd - writeOffset else { throw URLError(.badServerResponse) }
            try file.seek(toOffset: UInt64(writeOffset))
            try file.write(contentsOf: data)
            let start = writeOffset
            writeOffset += Int64(data.count)
            addRange(start..<writeOffset)
            // Publish the completed file before handing the final bytes to AVPlayer.
            // Playback may end or switch songs before URLSession reports task completion.
            persistCompletedFileIfNeeded()
            if !stopped { serveRequests() }
        } catch { fail(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped else { return }
        self.task = nil
        if let error, (error as? URLError)?.code != .cancelled, !isComplete {
            fail(error)
            return
        }
        if terminalError != nil { return }
        if error == nil {
            if length == nil { length = writeOffset }
            guard writeOffset == requestEnd || requestEnd == Int64.max else {
                fail(URLError(.networkConnectionLost))
                return
            }
        }
        serveRequests()
        persistCompletedFileIfNeeded()
        if isComplete { session.finishTasksAndInvalidate() }
        if playbackReleased, reportedCompletion { stop() }
        else { fetchNextRange() }
    }

    private var isComplete: Bool {
        guard let length, length > 0 else { return false }
        return ranges == [0..<length]
    }

    private func persistCompletedFileIfNeeded() {
        guard isComplete, !reportedCompletion else { return }
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("yorune-complete-\(UUID().uuidString)")
        do {
            // Keep the player's file readable while the offline library takes ownership.
            do { try FileManager.default.linkItem(at: fileURL, to: owned) }
            catch { try FileManager.default.copyItem(at: fileURL, to: owned) }
            report(.success(NavidromeDownload(temporaryURL: owned, suggestedFilename: filename, mimeType: mimeType)))
        } catch {
            try? FileManager.default.removeItem(at: owned)
            report(.failure(error))
        }
    }

    private func addRange(_ range: Range<Int64>) {
        var merged: [Range<Int64>] = []
        for range in (ranges + [range]).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, last.upperBound >= range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        ranges = merged
    }

    private func serveRequests() {
        requests.removeAll { request in
            if let terminalError {
                request.finishLoading(with: terminalError)
                return true
            }
            if let info = request.contentInformationRequest {
                guard let length, let mimeType else { return false }
                info.contentLength = length
                info.contentType = UTType(mimeType: mimeType)?.identifier
                info.isByteRangeAccessSupported = true
            }
            guard let data = request.dataRequest else {
                request.finishLoading()
                return true
            }
            var offset = max(data.currentOffset, data.requestedOffset)
            let end = data.requestsAllDataToEndOfResource
                ? (length ?? Int64.max)
                : min(data.requestedOffset + Int64(data.requestedLength), length ?? Int64.max)
            while offset < end, let range = ranges.first(where: { $0.contains(offset) }) {
                do {
                    try file.seek(toOffset: UInt64(offset))
                    let count = Int(min(min(range.upperBound, end) - offset, 256 * 1024))
                    let bytes = try file.read(upToCount: count) ?? Data()
                    guard !bytes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    data.respond(with: bytes)
                    let next = max(data.currentOffset, data.requestedOffset)
                    guard next > offset else { break }
                    offset = next
                } catch {
                    request.finishLoading(with: error)
                    return true
                }
            }
            if offset >= end {
                request.finishLoading()
                return true
            }
            return false
        }
    }

    private func fail(_ error: Error) {
        terminalError = error
        session.invalidateAndCancel()
        serveRequests()
        report(.failure(error))
    }

    private func report(_ result: Result<NavidromeDownload, Error>) {
        guard !reportedCompletion else { return }
        reportedCompletion = true
        completion(result)
        if playbackReleased { stop() }
    }
}
