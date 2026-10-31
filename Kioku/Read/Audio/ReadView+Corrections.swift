import SwiftUI

// The correction pass after an alignment: when the aligner struggled somewhere, offer to fix those
// words; accepting returns to the Read tab, where tapping a squiggle edits its text instead of opening
// the lookup; OK re-aligns with the fixed lyrics, Cancel puts everything back, and both return to
// the lyric view.
extension ReadView {
    // Offers the correction pass when the fresh alignment left squiggles.
    @MainActor
    func offerCorrectionsIfNeeded() {
        let count = AlignmentStruggleSpans.ranges(
            cues: audioPlayback.audioAttachmentCues, highlightRanges: audioPlayback.audioAttachmentHighlightRanges
        ).count
        guard count > 0, audioPlayback.isCorrecting == false else { return }
        audioPlayback.correctionOfferCount = count
        audioPlayback.isShowingCorrectionOffer = true
    }

    // Enters correction mode: remembers the aligned cues for Cancel and shows the Read tab.
    @MainActor
    func beginCorrections() {
        audioPlayback.correctionSession = AlignmentCorrectionSession(cues: audioPlayback.audioAttachmentCues)
        audioPlayback.isCorrecting = true
        audioPlayback.isShowingLyricsView = false
    }

    // A tap on a squiggle during a correction pass opens the editor for that word.
    @MainActor
    func openStruggleTarget(_ target: StruggleTarget) {
        audioPlayback.correctionTarget = target
        audioPlayback.correctionText = target.text
        audioPlayback.isShowingCorrectionEditor = true
    }

    // Writes the retyped word into the note (and the timed lyrics) and remembers how to undo it.
    @MainActor
    func applyCorrection() {
        guard let target = audioPlayback.correctionTarget else { return }
        let replacement = audioPlayback.correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard replacement.isEmpty == false, replacement != target.text else { return }
        replaceNoteText([TextConversion(range: target.range, original: target.text, replacement: replacement, source: .alignment)])
        audioPlayback.correctionSession?.edits.append(
            (range: NSRange(location: target.range.location, length: (replacement as NSString).length), original: target.text)
        )
    }

    // OK re-aligns when anything was corrected; Cancel undoes every edit and restores the aligned
    // cues. Either way the lyric view comes back.
    @MainActor
    func finishCorrections(apply: Bool) {
        guard let session = audioPlayback.correctionSession else { return }
        audioPlayback.isCorrecting = false
        audioPlayback.correctionSession = nil
        audioPlayback.isShowingLyricsView = true
        if apply {
            if session.edits.isEmpty == false { Task { await realignWholeNote() } }
            return
        }
        for edit in session.edits.reversed() {
            replaceNoteText([TextConversion(range: edit.range, original: "", replacement: edit.original, source: .alignment)])
        }
        guard session.edits.isEmpty == false else { return }
        audioPlayback.audioAttachmentCues = session.cues
        audioPlayback.audioController.updateCues(session.cues)
        audioPlayback.audioAttachmentHighlightRanges = SubtitleParser.resolveHighlightRanges(for: session.cues, in: document.text)
        if let attachmentID = audioPlayback.activeAudioAttachmentID {
            do {
                try NotesAudioStore.shared.saveCues(session.cues, attachmentID: attachmentID)
            } catch {
                AppLog.error(.storage, "[ReadView] restoring cues after cancelled corrections failed: \(error.localizedDescription)")
            }
        }
    }

    // The bottom bar of a correction pass: Cancel and OK, with a hint at what a tap does.
    @ViewBuilder
    var correctionBar: some View {
        if audioPlayback.isCorrecting {
            HStack {
                Button("Cancel") { finishCorrections(apply: false) }
                Spacer()
                Text("Tap a squiggle to correct it")
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("OK") { finishCorrections(apply: true) }
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}
