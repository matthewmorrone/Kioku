import Foundation
import UIKit
import Vision

// Picks the best-looking stretch of a video to loop when the video can't follow the song. Scores the
// video's preview frames with Apple's on-device image-aesthetics model (a trained vision model, not a
// language model), marking down title cards and text slides (which it flags as "utility" images) and
// near-black frames, then takes the window of frames with the best average. One run per video per
// launch; every player showing the same video shares the answer.
actor YouTubeClipFinder {
    static let shared = YouTubeClipFinder()

    // How long the looped stretch runs, in seconds.
    private static let clipSeconds = 10.0

    private var tasks: [String: Task<YouTubeClip?, Never>] = [:]

    // The clip to loop for `videoID`, or nil when its frames can't be fetched or scored.
    func clip(for videoID: String) async -> YouTubeClip? {
        if let running = tasks[videoID] { return await running.value }
        let task = Task { await Self.findClip(videoID: videoID) }
        tasks[videoID] = task
        return await task.value
    }

    // Fetches the frames, scores each, and returns the best window (skipping the intro and outro
    // tenths, which are usually logos and credits).
    private static func findClip(videoID: String) async -> YouTubeClip? {
        guard let frames = await YouTubeStoryboard.frames(videoID: videoID) else { return nil }
        var scores: [Double] = []
        for image in frames.images { scores.append(await score(image)) }
        let window = max(1, Int((clipSeconds / frames.interval).rounded()))
        let margin = frames.images.count / 10
        let lower = frames.images.count > window + 2 * margin ? margin : 0
        let upper = frames.images.count > window + 2 * margin ? frames.images.count - margin - window : max(0, frames.images.count - window)
        guard upper >= lower else { return nil }
        var bestStart = lower
        var bestMean = -Double.infinity
        for start in lower ... upper {
            let slice = scores[start ..< min(scores.count, start + window)]
            let mean = slice.reduce(0, +) / Double(slice.count)
            if mean > bestMean { (bestMean, bestStart) = (mean, start) }
        }
        let start = Double(bestStart) * frames.interval
        AppLog.info(.audioPlayback, "youtube \(videoID) loop clip \(start)s for \(Double(window) * frames.interval)s, score \(bestMean)")
        return YouTubeClip(start: start, end: start + Double(window) * frames.interval)
    }

    // A frame's appeal: the aesthetics model's overall score, marked down for utility images and
    // for frames that are nearly black. Unscorable frames count as poor, not as errors.
    private static func score(_ image: CGImage) async -> Double {
        var value = 0.0
        do {
            let result = try await CalculateImageAestheticsScoresRequest().perform(on: image)
            value = Double(result.overallScore)
            if result.isUtility { value -= 1 }
        } catch {
            AppLog.error(.audioPlayback, "frame aesthetics scoring failed — \(error.localizedDescription)")
            return -2
        }
        if averageBrightness(of: image) < 0.08 { value -= 1 }
        return value
    }

    // The frame's mean brightness, 0 to 1, from a one-pixel redraw.
    private static func averageBrightness(of image: CGImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 1 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])) / 255
    }
}
