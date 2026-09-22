import SwiftUI

// The minimized "now playing" control: takes over the title row's lyrics (♪) button slot
// (ReadView+TitleView.swift) once a note's audio has actually started and the full-screen
// lyrics overlay (LyricsView) is dismissed — otherwise pausing, resuming, or seeing where
// playback is means reopening the whole karaoke view. Tapping the scrubber area reopens it.
extension ReadView {
    // Playing-but-hidden, or paused mid-track but hidden — either way there's something to
    // resume/scrub. An attachment that's never been started (currentTimeMs still 0) has nothing
    // to show yet, so the title row keeps its normal buttons until playback actually begins.
    var isShowingLyricsMiniPlayer: Bool {
        audioPlayback.activeAudioAttachmentID != nil
            && audioPlayback.isShowingLyricsView == false
            && (audioPlayback.audioController.isPlaying || audioPlayback.audioController.currentTimeMs > 0)
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audioPlayback.audioController.isPlaying ? "Pause" : "Play")

            // The slider itself keeps its own drag gesture for scrubbing (a tap-to-reopen layered
            // on top of it would fight that), so reopening the full view is a separate small
            // target rather than the whole scrubber.
            LyricsScrubber(
                controller: audioPlayback.audioController,
                isScrubbing: $isMiniPlayerScrubbing
            )

            // Same glyph as titleLyricsButton (music.note) rather than a chevron — this is still
            // the lyrics control, just minimized, so tapping it to bring back the full view reads
            // as "the same button, restored" instead of an unrelated disclosure affordance.
            Button {
                audioPlayback.isShowingLyricsView = true
            } label: {
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reopen lyrics")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Capsule().fill(ReadToggleAppearance.background))
    }
}
