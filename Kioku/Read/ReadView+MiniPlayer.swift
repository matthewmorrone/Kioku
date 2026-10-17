import SwiftUI

// The minimized "now playing" control: fills the title row's empty leading space
// (ReadView+TitleView.swift) once a note's audio has actually started and the full-screen
// lyrics overlay (LyricsView) is dismissed — otherwise pausing, resuming, or seeing where
// playback is means reopening the whole karaoke view. The row's own ♪ button reopens it; press
// and hold on play/pause stops playback and hides the control.
extension ReadView {
    // Playing-but-hidden, or paused mid-track but hidden — either way there's something to
    // resume/scrub. An attachment that's never been started (currentTimeMs still 0) has nothing
    // to show yet, so the title row keeps its normal buttons until playback actually begins.
    var isShowingLyricsMiniPlayer: Bool {
        audioPlayback.activeAudioAttachmentID != nil
            && audioPlayback.isShowingLyricsView == false
            && (audioPlayback.audioController.isPlaying || audioPlayback.audioController.currentTimeMs > 0)
    }

    // Press and hold on the mini player's play button: ends playback. Stopping rewinds to the
    // start, so isShowingLyricsMiniPlayer turns false and the control leaves the title row.
    // Not on the scrubber, whose drag a long-press menu would fight.
    @ViewBuilder
    var lyricsMiniPlayerStopMenu: some View {
        Button(role: .destructive) {
            audioPlayback.audioController.stop()
        } label: {
            Label("Stop Playback", systemImage: "xmark")
        }
    }

    var lyricsMiniPlayerInlineControl: some View {
        HStack(spacing: 8) {
            Button {
                if audioPlayback.audioController.isPlaying {
                    audioPlayback.audioController.pause()
                } else {
                    audioPlayback.audioController.play()
                }
            } label: {
                Image(systemName: audioPlayback.audioController.isPlaying ? "pause.fill" : "play.fill")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audioPlayback.audioController.isPlaying ? "Pause" : "Play")
            .contextMenu { lyricsMiniPlayerStopMenu }

            LyricsScrubber(
                controller: audioPlayback.audioController,
                isScrubbing: $isMiniPlayerScrubbing
            )
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(Capsule().fill(ReadToggleAppearance.background))
    }
}
