import AVFoundation
import AVKit
import Combine
import UIKit

// Runs the cast flow: render the lyric video for the song (or reuse the one made for the same
// song and settings), pause Kioku's own playback, and open the video in the full-screen player at
// the same position. The TV button reads `renderProgress` to show a spinner while it renders.
@MainActor
final class LyricVideoCaster: ObservableObject {
    static let shared = LyricVideoCaster()

    // 0...1 while a video is being rendered; nil otherwise.
    @Published private(set) var renderProgress: Double?
    private var renderTask: Task<Void, Never>?

    // Casts `input` as `mode`, starting at the controller's position; `controller` is paused for
    // the cast and seeked to where the video stopped. Ignored while a render is running.
    func cast(input: LyricVideoInput, mode: TVCastMode, controller: AudioPlaybackController) {
        guard renderTask == nil else { return }
        let url = Self.videoURL(for: input, mode: mode)
        let startMs = controller.currentTimeMs
        renderTask = Task {
            defer { renderTask = nil; renderProgress = nil }
            if FileManager.default.fileExists(atPath: url.path) == false {
                renderProgress = 0
                do {
                    try await LyricVideoRenderer.render(input: input, mode: mode, to: url) { [weak self] value in
                        self?.renderProgress = value
                    }
                } catch is CancellationError {
                    return
                } catch {
                    AppLog.error(.audioPlayback, "[LyricVideo] render failed: \(error)")
                    try? FileManager.default.removeItem(at: url)
                    return
                }
            }
            present(url: url, startMs: startMs, controller: controller)
        }
    }

    // Opens the player over the top view controller, with Kioku's audio paused underneath.
    private func present(url: URL, startMs: Int, controller: AudioPlaybackController) {
        guard let top = Self.topViewController() else {
            AppLog.error(.audioPlayback, "[LyricVideo] no view controller to present the player from")
            return
        }
        controller.pause()
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = true
        let viewController = LyricVideoPlayerViewController()
        viewController.player = player
        viewController.modalPresentationStyle = .fullScreen
        viewController.onClose = { positionMs in controller.seek(toMs: positionMs) }
        top.present(viewController, animated: true) {
            player.seek(to: CMTime(value: CMTimeValue(startMs), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                player.play()
            }
        }
    }

    // Where the video for this song, mode and settings lives; other videos of the same song and
    // mode are removed first so only the current one is kept.
    private static func videoURL(for input: LyricVideoInput, mode: TVCastMode) -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LyricVideos", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            AppLog.error(.audioPlayback, "[LyricVideo] cannot create cache folder: \(error)")
        }
        let prefix = "\(input.noteID?.uuidString ?? "note")-\(mode.rawValue)-"
        let current = "\(prefix)\(input.cacheKey).mp4"
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in existing where name.hasPrefix(prefix) && name != current {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return directory.appendingPathComponent(current)
    }

    // The frontmost presented view controller of the active window scene.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
