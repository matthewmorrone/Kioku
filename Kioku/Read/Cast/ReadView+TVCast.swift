import Foundation

// The TV button's action: turns the song this view has loaded into a lyric video and plays it.
extension ReadView {
    // Builds the lyric video input from the loaded song and hands it to the caster; logs and does
    // nothing when no song with lyrics words is loaded.
    func castLyricVideo(mode: TVCastMode) {
        let controller = audioPlayback.audioController
        guard let audioURL = controller.currentAudioURL,
              let input = LyricVideoInputBuilder.make(
                cues: audioPlayback.audioAttachmentCues,
                highlightRanges: audioPlayback.audioAttachmentHighlightRanges,
                noteText: document.text,
                segmentationRanges: document.segmentRanges,
                furiganaBySegmentLocation: document.furiganaBySegmentLocation,
                furiganaLengthBySegmentLocation: document.furiganaLengthBySegmentLocation,
                noteID: document.activeNoteID,
                breakdownStore: songBreakdownStore,
                dictionaryGloss: { location, surface in lyricWordGloss(at: location, surface: surface) },
                isParticle: { location, surface in isLyricParticle(at: location, surface: surface) },
                isLoanword: { isLyricLoanword($0) },
                audioURL: audioURL,
                durationSeconds: controller.duration
              ) else {
            AppLog.info(.audioPlayback, "[LyricVideo] nothing to cast: no loaded song with lyrics words")
            return
        }
        LyricVideoCaster.shared.cast(input: input, mode: mode, controller: controller)
    }
}
