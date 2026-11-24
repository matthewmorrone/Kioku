import Foundation

// Fetches a YouTube video's uploader-written Japanese captions as plain lines, for offering as a
// note's lyrics. Reads the track list from the same unofficial player response as the audio
// download. Auto-generated tracks are ignored (speech recognition over singing is unusable), so it
// returns nil when there is no written Japanese track. Network and format failures are logged and also return nil: captions are an offer, never a
// reason to block adding the video.
enum YouTubeCaptionFetcher {
    // Returns the video's written Japanese captions, or nil when it has none or they can't be read.
    static func japaneseCaptions(videoID: String) async -> YouTubeCaptions? {
        do {
            let player = try await YouTubePlayerAPI.playerResponse(videoID: videoID)
            let tracklist = (player["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any]
            let tracks = (tracklist?["captionTracks"] as? [[String: Any]] ?? [])
                .filter { (($0["languageCode"] as? String) ?? "").hasPrefix("ja") }
            // A manual track has no "kind"; "asr" marks speech-recognition output, which is skipped.
            let chosen = tracks.first { ($0["kind"] as? String) != "asr" }
            guard let chosen, let base = chosen["baseUrl"] as? String,
                  let url = URL(string: base + "&fmt=json3") else { return nil }

            var request = URLRequest(url: url)
            request.setValue(YouTubePlayerAPI.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let lines = try lines(fromJSON3: data)
            guard lines.isEmpty == false else { return nil }
            return YouTubeCaptions(text: lines.joined(separator: "\n"))
        } catch {
            AppLog.error(.audioAlignment, "youtube \(videoID) captions unavailable — \(error.localizedDescription)")
            return nil
        }
    }

    // The caption lines in YouTube's json3 format: each event's text segments joined and trimmed,
    // empty events (the format's line-break padding) dropped.
    static func lines(fromJSON3 data: Data) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { event in
            guard let segments = event["segs"] as? [[String: Any]] else { return nil }
            let line = segments.compactMap { $0["utf8"] as? String }.joined()
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
    }
}
