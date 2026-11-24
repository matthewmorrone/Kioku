import Foundation

// One storyboard download per video per launch, shared by everything that reads a video's preview
// frames (the loop-clip finder and the black-bar finder), so the sprite sheets are fetched once.
actor YouTubeStoryboardCache {
    static let shared = YouTubeStoryboardCache()

    private var tasks: [String: Task<YouTubeStoryboard.Frames?, Never>] = [:]

    // The preview frames for `videoID`, fetched on first request and reused afterwards; nil when the
    // video has none (the failure is logged by the fetch).
    func frames(for videoID: String) async -> YouTubeStoryboard.Frames? {
        if let running = tasks[videoID] { return await running.value }
        let task = Task { await YouTubeStoryboard.frames(videoID: videoID) }
        tasks[videoID] = task
        return await task.value
    }
}
