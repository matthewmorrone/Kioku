import Foundation

// Searches YouTube by text for the video picker. Uses the unofficial web-client search endpoint
// (the iOS client's search response is a server-driven layout with no stable video list), so like
// the rest of the YouTube support it may break without notice.
enum YouTubeSearch {
    // Returns one page of video results for `query`, or the page after `continuation`; throws on
    // network or format failure so the picker can say why it is empty.
    static func search(query: String, continuation: String? = nil) async throws -> YouTubeSearchPage {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false") else {
            return YouTubeSearchPage(results: [], continuation: nil)
        }
        var body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20250101.00.00", "hl": "ja", "gl": "JP"]]
        ]
        if let continuation { body["continuation"] = continuation } else { body["query"] = query }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 Version/18.3 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) == false {
            AppLog.error(.audioAlignment, "youtube search HTTP \(http.statusCode)")
            throw YouTubeAudioFailure.badResponse(http.statusCode)
        }
        let root = try JSONSerialization.jsonObject(with: data)
        return YouTubeSearchPage(results: videoRenderers(in: root).compactMap(result(from:)), continuation: continuationToken(in: root))
    }

    // The token for the next page: the first continuation command in the response, if any.
    private static func continuationToken(in node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let command = dict["continuationCommand"] as? [String: Any], let token = command["token"] as? String { return token }
            for value in dict.values { if let token = continuationToken(in: value) { return token } }
        } else if let list = node as? [Any] {
            for value in list { if let token = continuationToken(in: value) { return token } }
        }
        return nil
    }

    // Every `videoRenderer` object in the response, in page order; the nesting above them varies
    // with sections and ads, so this walks the tree instead of following a fixed path.
    private static func videoRenderers(in node: Any) -> [[String: Any]] {
        if let dict = node as? [String: Any] {
            var found: [[String: Any]] = []
            if let renderer = dict["videoRenderer"] as? [String: Any] { found.append(renderer) }
            for value in dict.values { found.append(contentsOf: videoRenderers(in: value)) }
            return found
        }
        if let list = node as? [Any] {
            return list.flatMap { videoRenderers(in: $0) }
        }
        return []
    }

    // Maps one renderer to a result, nil when it lacks an id or title (live promos, shelves).
    private static func result(from renderer: [String: Any]) -> YouTubeSearchResult? {
        guard let id = renderer["videoId"] as? String, YouTubeVideoID.isValid(id),
              let title = ((renderer["title"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String
        else { return nil }
        let channel = (((renderer["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let duration = ((renderer["lengthText"] as? [String: Any])?["simpleText"] as? String) ?? ""
        // Thumbnails arrive as protocol-relative or absolute URLs; the standard-quality frame is stable.
        let thumb = URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
        // The subtitle badge reads "CC" or its localized form (字幕 under the ja interface language).
        let badges = (renderer["badges"] as? [[String: Any]] ?? [])
            .compactMap { ($0["metadataBadgeRenderer"] as? [String: Any])?["label"] as? String }
        let hasSubtitles = badges.contains { $0 == "CC" || $0 == "字幕" }
        return YouTubeSearchResult(videoID: id, title: title, channel: channel, duration: duration, thumbnailURL: thumb, hasSubtitles: hasSubtitles)
    }
}
