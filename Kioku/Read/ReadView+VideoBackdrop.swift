import SwiftUI

// The note's YouTube video behind the Read screen, so the video shows whether or not the lyrics view
// is open. The one video player lives here; the lyrics view draws over it.
extension ReadView {
    // True when the open note has audio and a video to play along with it.
    var hasVideoBackdrop: Bool {
        audioPlayback.youTubeVideoID != nil && audioPlayback.activeAudioAttachmentID != nil
    }

    // The Read content hides while the lyrics view is up over the video, as the video used to cover it.
    var readContentOpacity: Double {
        hasVideoBackdrop && audioPlayback.isShowingLyricsView ? 0 : 1
    }

    // The screen's background: the plain page, or the video under the dark veil. The same backdrop sits behind the Read text and
    // the lyrics view; the veil only drops away in the lyrics view's video-only layout.
    @ViewBuilder
    var readBackdrop: some View {
        ZStack {
            Color(.systemBackground)
            if hasVideoBackdrop, let videoID = audioPlayback.youTubeVideoID {
                YouTubeFollowerView(
                    videoID: videoID,
                    audio: audioPlayback.audioController,
                    onLengthMismatch: { audioPlayback.videoLengthMismatch = $0 }
                )
                .id(videoID)
                if audioPlayback.isShowingLyricsView && audioPlayback.isVideoMode {
                    Color.clear
                } else {
                    Color.black.opacity(0.68)
                }
            }
        }
        .ignoresSafeArea()
    }
}
