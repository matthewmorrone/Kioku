import Foundation
import UIKit

// Fetches a video's storyboard: the small preview frames YouTube cuts a video into for its scrub
// bar, delivered as sprite sheets. They give a spread of frames across the whole video for the
// price of a few small images, with no video download. Comes from the same unofficial player
// response as the audio and captions, so it may break without notice.
enum YouTubeStoryboard {
    // The video's preview frames in order, and the seconds between consecutive frames.
    struct Frames {
        let images: [CGImage]
        let interval: Double
    }

    // Downloads the sharpest storyboard level and cuts its sheets into frames. Returns nil when the
    // video has no storyboard or it can't be read; failures are logged.
    static func frames(videoID: String) async -> Frames? {
        do {
            let player = try await YouTubePlayerAPI.playerResponse(videoID: videoID)
            let renderer = (player["storyboards"] as? [String: Any])?["playerStoryboardSpecRenderer"] as? [String: Any]
            guard let spec = renderer?["spec"] as? String else { return nil }
            let parts = spec.split(separator: "|").map(String.init)
            guard parts.count > 1 else { return nil }
            // Levels are listed smallest first; take the largest that is still a modest download.
            var best: (index: Int, fields: [String], tileWidth: Int)?
            for (offset, level) in parts.dropFirst().enumerated() {
                let fields = level.components(separatedBy: "#")
                guard fields.count >= 8, let width = Int(fields[0]), let interval = Double(fields[5]), interval > 0, width <= 200 else { continue }
                if width >= (best?.tileWidth ?? 0) { best = (offset, fields, width) }
            }
            guard let best,
                  let tileWidth = Int(best.fields[0]), let tileHeight = Int(best.fields[1]),
                  let count = Int(best.fields[2]), let columns = Int(best.fields[3]), let rows = Int(best.fields[4]),
                  let intervalMs = Double(best.fields[5]) else { return nil }
            // The spec gives the gap between frames in milliseconds; everything else here is seconds.
            let interval = intervalMs / 1000
            let perSheet = columns * rows
            guard perSheet > 0, count > 0 else { return nil }
            let sigh = best.fields[7].replacingOccurrences(of: "$", with: "%24")

            var images: [CGImage] = []
            for sheet in 0 ..< (count + perSheet - 1) / perSheet {
                let name = best.fields[6].replacingOccurrences(of: "$M", with: String(sheet))
                let address = parts[0]
                    .replacingOccurrences(of: "$L", with: String(best.index))
                    .replacingOccurrences(of: "$N", with: name) + "&sigh=" + sigh
                guard let url = URL(string: address) else { continue }
                var request = URLRequest(url: url)
                request.setValue(YouTubePlayerAPI.userAgent, forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let sheetImage = UIImage(data: data)?.cgImage else { continue }
                for position in 0 ..< perSheet where images.count < count {
                    let rect = CGRect(x: (position % columns) * tileWidth, y: (position / columns) * tileHeight, width: tileWidth, height: tileHeight)
                    guard let tile = sheetImage.cropping(to: rect) else { continue }
                    images.append(tile)
                }
            }
            return images.isEmpty ? nil : Frames(images: images, interval: interval)
        } catch {
            AppLog.error(.audioPlayback, "youtube \(videoID) storyboard unavailable — \(error.localizedDescription)")
            return nil
        }
    }
}
