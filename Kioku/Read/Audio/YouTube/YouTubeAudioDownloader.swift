import Foundation

// Fetches a YouTube video's audio track to a temporary .m4a so the on-device aligner can hear it,
// the same as a picked audio file. Asks YouTube's player endpoint (as its iOS client does) for the
// stream list and downloads the AAC-LC track in ranged chunks.
// This is an unofficial interface: YouTube can change or restrict it at any time, so every failure
// surfaces as a typed error the caller shows rather than being swallowed.
enum YouTubeAudioDownloader {
    // itag 140 is the 128 kbps AAC-LC m4a track, which AVAudioPlayer plays and the aligner reads.
    private static let audioItag = 140
    private static let chunkBytes = 4 * 1024 * 1024
    // A song is a few MB; this ceiling only stops a runaway stream from filling the disk.
    private static let maxBytes = 120 * 1024 * 1024

    // Downloads `videoID`'s audio and returns the temp file plus the video's title.
    // Reports 0…1 progress through `onProgress`; honours task cancellation and `isCancelled` between chunks.
    static func download(
        videoID: String,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> YouTubeAudioDownload {
        let player = try await YouTubePlayerAPI.playerResponse(videoID: videoID)
        let status = player["playabilityStatus"] as? [String: Any]
        if let state = status?["status"] as? String, state != "OK" {
            throw YouTubeAudioFailure.unplayable((status?["reason"] as? String) ?? state.lowercased())
        }

        let formats = (player["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]] ?? []
        guard let format = formats.first(where: { ($0["itag"] as? Int) == audioItag && $0["url"] is String }),
              let urlString = format["url"] as? String,
              let streamURL = URL(string: urlString) else {
            throw YouTubeAudioFailure.noAudioStream
        }
        let total = Int((format["contentLength"] as? String) ?? "") ?? 0
        guard total <= maxBytes else { throw YouTubeAudioFailure.noAudioStream }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("youtube-\(videoID)-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { handle.closeFile() }
            try await write(stream: streamURL, total: total, to: handle, isCancelled: isCancelled, onProgress: onProgress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let title = ((player["videoDetails"] as? [String: Any])?["title"] as? String) ?? ""
        return YouTubeAudioDownload(fileURL: destination, title: title)
    }

    // Streams the track into `handle` one ranged request at a time. Ranged requests keep each
    // transfer small and let cancellation land between chunks. Stops when the declared length is
    // reached, or on a short chunk when the length is unknown.
    private static func write(
        stream: URL,
        total: Int,
        to handle: FileHandle,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var offset = 0
        var finished = false
        while finished == false {
            try Task.checkCancellation()
            if isCancelled() { throw CancellationError() }
            guard let chunkURL = rangedURL(stream, from: offset, to: offset + chunkBytes - 1) else {
                throw YouTubeAudioFailure.noAudioStream
            }
            var request = URLRequest(url: chunkURL)
            request.setValue(YouTubePlayerAPI.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) == false {
                AppLog.error(.audioAlignment, "youtube stream chunk at byte \(offset) HTTP \(http.statusCode) host \(chunkURL.host ?? "?")")
                throw YouTubeAudioFailure.badResponse(http.statusCode)
            }
            try handle.write(contentsOf: data)
            offset += data.count
            finished = data.count < chunkBytes || (total > 0 && offset >= total) || offset >= maxBytes
            if total > 0 { onProgress(min(1, Double(offset) / Double(total))) }
        }
    }

    // `url` with a `range=a-b` query item, which is how the stream servers take byte ranges.
    private static func rangedURL(_ url: URL, from: Int, to: Int) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "range" }
        items.append(URLQueryItem(name: "range", value: "\(from)-\(to)"))
        components.queryItems = items
        return components.url
    }
}
