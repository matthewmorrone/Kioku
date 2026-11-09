import AVKit
import UIKit

// The full-screen player the cast video plays in on the phone. Its controls carry the system AirPlay
// button, so choosing the TV there sends the lyric video to it. When it closes it stops the video
// and reports where it got to, so Kioku's own playback can pick up from there.
final class LyricVideoPlayerViewController: AVPlayerViewController {
    // Called once on close with the video's position in ms.
    var onClose: ((Int) -> Void)?
    private var didReportClose = false

    // Pauses and reports the position when the player is dismissed.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard (isBeingDismissed || isMovingFromParent || presentingViewController == nil), didReportClose == false else { return }
        didReportClose = true
        let seconds = player?.currentTime().seconds ?? 0
        player?.pause()
        onClose?(seconds.isFinite ? max(0, Int(seconds * 1000)) : 0)
    }
}
