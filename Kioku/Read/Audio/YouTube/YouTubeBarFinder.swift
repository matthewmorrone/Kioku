import CoreGraphics
import Foundation

// Finds the black borders inside a video's picture by looking at its preview frames. An edge counts
// as border only if it is black in most frames, so a dark scene doesn't read as a bar. One run per
// video per launch.
actor YouTubeBarFinder {
    static let shared = YouTubeBarFinder()

    // A pixel at or below this brightness (0–255) counts as black; compression leaves bars a few levels above 0.
    private static let blackLevel: UInt8 = 28
    // Borders thinner than this fraction of the frame aren't worth a zoom.
    private static let minimumBar = 0.02
    // No border is trusted past this fraction, which keeps a misread from cropping the picture away.
    private static let maximumBar = 0.4

    private var tasks: [String: Task<YouTubeVideoBars, Never>] = [:]

    // The borders for `videoID`, or none when its frames can't be fetched or show no consistent border.
    func bars(for videoID: String) async -> YouTubeVideoBars {
        if let running = tasks[videoID] { return await running.value }
        let task = Task { await Self.findBars(videoID: videoID) }
        tasks[videoID] = task
        return await task.value
    }

    // Measures every frame, then takes a low percentile per edge so only borders present in most frames survive.
    private static func findBars(videoID: String) async -> YouTubeVideoBars {
        guard let frames = await YouTubeStoryboardCache.shared.frames(for: videoID), frames.images.count >= 8 else { return .none }
        let measured = frames.images.compactMap(measure)
        guard measured.count >= 8 else { return .none }
        // The border on one edge: the 25th-percentile measurement across frames, zeroed when too thin and capped when too thick.
        func edge(_ value: KeyPath<YouTubeVideoBars, Double>) -> Double {
            let sorted = measured.map { $0[keyPath: value] }.sorted()
            let bar = sorted[sorted.count / 4]
            return bar < minimumBar ? 0 : min(bar, maximumBar)
        }
        // Letterbox and pillarbox bars come in pairs, so a bar found on one side stands for the other
        // too (a stray bright edge column in the preview frames can hide one of the pair).
        // A video that isn't 16:9 is shown with bars the player adds itself, which the preview frames
        // (cut to the picture) don't contain; its shape gives them exactly. Bars painted into the
        // picture then sit inside what is left.
        let aspect = Double(frames.images[0].width) / Double(frames.images[0].height)
        let frameAspect = 16.0 / 9.0
        let shapeHorizontal = aspect < frameAspect * 0.98 ? (1 - aspect / frameAspect) / 2 : 0
        let shapeVertical = aspect > frameAspect * 1.02 ? (1 - frameAspect / aspect) / 2 : 0
        let paintedVertical = max(edge(\.top), edge(\.bottom))
        let paintedHorizontal = max(edge(\.left), edge(\.right))
        let vertical = shapeVertical + paintedVertical * (1 - 2 * shapeVertical)
        let horizontal = shapeHorizontal + paintedHorizontal * (1 - 2 * shapeHorizontal)
        let bars = YouTubeVideoBars(top: vertical, bottom: vertical, left: horizontal, right: horizontal)
        AppLog.info(.audioPlayback, "youtube \(videoID) black bars top \(bars.top) bottom \(bars.bottom) left \(bars.left) right \(bars.right)")
        return bars
    }

    // One frame's black edges as fractions, or nil for a frame that is mostly black (a fade or title card).
    private static func measure(_ image: CGImage) -> YouTubeVideoBars? {
        let width = image.width, height = image.height
        guard width > 8, height > 8 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Whether row `y` is black, allowing the odd stray pixel a preview frame's compression leaves.
        func rowIsBlack(_ y: Int) -> Bool { (0 ..< width).filter { pixels[y * width + $0] > blackLevel }.count <= width / 50 }
        // Whether column `x` is black, with the same tolerance.
        func columnIsBlack(_ x: Int) -> Bool { (0 ..< height).filter { pixels[$0 * width + x] > blackLevel }.count <= height / 50 }
        var top = 0
        while top < height, rowIsBlack(top) { top += 1 }
        var bottom = 0
        while bottom < height - top, rowIsBlack(height - 1 - bottom) { bottom += 1 }
        var left = 0
        while left < width, columnIsBlack(left) { left += 1 }
        var right = 0
        while right < width - left, columnIsBlack(width - 1 - right) { right += 1 }
        let vertical = Double(top + bottom) / Double(height)
        let horizontal = Double(left + right) / Double(width)
        guard vertical < 0.8, horizontal < 0.8 else { return nil }
        return YouTubeVideoBars(top: Double(top) / Double(height), bottom: Double(bottom) / Double(height),
                                left: Double(left) / Double(width), right: Double(right) / Double(width))
    }
}
