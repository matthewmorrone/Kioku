import Foundation

// One video from a YouTube search: what the picker shows so the right upload can be chosen.
struct YouTubeSearchResult: Identifiable {
    let videoID: String
    let title: String
    let channel: String
    let duration: String
    let thumbnailURL: URL?
    // True when YouTube marks the video as carrying uploader-written subtitles (its "CC" badge);
    // auto-generated captions don't earn the badge.
    var hasSubtitles = false

    var id: String { videoID }

    // The length in seconds parsed from "m:ss" or "h:mm:ss"; nil when the result shows none (live streams).
    var durationSeconds: Double? {
        let parts = duration.split(separator: ":").compactMap { Double($0) }
        guard parts.isEmpty == false, parts.count == duration.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

// One page of search results and the token that fetches the next page (nil at the end).
struct YouTubeSearchPage {
    let results: [YouTubeSearchResult]
    let continuation: String?
}
