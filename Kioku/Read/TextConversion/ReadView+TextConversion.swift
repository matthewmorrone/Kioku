import Foundation

// The Read tab's Cleanup: English → katakana (EnglishKatakanaConverter) and width normalization
// (WidthNormalizer), collected into one review sheet, with the accepted proposals written back into
// the note. Started from the edit-mode button's display-options popover.
extension ReadView {
    // Whether Cleanup has anything to propose: Latin letters (ASCII or full-width) or half-width
    // kana / full-width digits. The popover's Cleanup row is dimmed without them.
    var noteNeedsCleanup: Bool {
        let hasLatin = document.text.unicodeScalars.contains { scalar in
            (scalar.isASCII && CharacterSet.letters.contains(scalar))
                || (0xFF21...0xFF3A).contains(scalar.value) || (0xFF41...0xFF5A).contains(scalar.value)
        }
        return hasLatin || WidthNormalizer.proposals(in: document.text).isEmpty == false
    }

    // Cleanup proposals for the current note, in the review sheet: English → katakana, plus width
    // fixes (half-width kana, full-width digits) wherever no katakana proposal already covers the run.
    func startCleanup() {
        guard let dictionaryStore else { return }
        let text = document.text
        let katakana = EnglishKatakanaConverter.proposals(
            in: text,
            lookup: { dictionaryStore.loanwordCandidates(for: $0) },
            isEnglish: { dictionaryStore.appearsInEnglishGloss($0) }
        )
        let width = WidthNormalizer.proposals(in: text).filter { fix in
            katakana.contains { NSIntersectionRange($0.range, fix.range).length > 0 } == false
        }
        presentTextConversion((katakana + width).sorted { $0.range.location < $1.range.location })
    }

    // Opens the review sheet on `proposals`, remembering the text they were computed against.
    private func presentTextConversion(_ proposals: [TextConversion]) {
        readSheets.isShowingDisplayOptions = false
        readSheets.textConversionSourceText = document.text
        readSheets.textConversionProposals = proposals
        readSheets.isShowingTextConversion = proposals.isEmpty == false
    }

    // Splices the accepted proposals into the note, last first so earlier ranges stay valid.
    // Segments are reconciled one replacement at a time, so user splits, merges and readings
    // survive everywhere except the replaced words themselves.
    func applyTextConversion() {
        defer {
            readSheets.isShowingTextConversion = false
            readSheets.textConversionProposals = []
        }
        // The note changed under the sheet; its ranges no longer point at the English.
        guard document.text == readSheets.textConversionSourceText else { return }
        let accepted = readSheets.textConversionProposals
            .filter { $0.isAccepted && $0.replacement.isEmpty == false }
            .sorted { $0.range.location > $1.range.location }
        guard accepted.isEmpty == false else { return }

        let updatedCues = convertedCues(for: accepted)
        var text = document.text
        var segments = document.segments
        for proposal in accepted {
            text = (text as NSString).replacingCharacters(in: proposal.range, with: proposal.replacement)
            if let current = segments { segments = reconcileSegments(current, to: text) }
        }

        document.segmentationRefreshTask?.cancel()
        document.furiganaComputationTask?.cancel()
        document.segmentLatticeEdges = []
        document.segmentEdges = []
        document.segmentRanges = []
        segmentSelection.selectedSegmentLocation = nil
        segmentSelection.selectedHighlightRangeOverride = nil
        segmentSelection.selectedBounds = nil
        document.segments = segments
        let restored = segments.map(furiganaFromSegmentRanges) ?? (byLocation: [:], lengthByLocation: [:])
        document.furiganaBySegmentLocation = restored.byLocation
        document.furiganaLengthBySegmentLocation = restored.lengthByLocation
        document.text = text
        // The song's saved alignment carries its own copy of each line; it gets the same edit, and
        // the cue ranges are re-resolved because the note text just changed length.
        if let updatedCues {
            audioPlayback.audioAttachmentCues = updatedCues
            audioPlayback.audioController.updateCues(updatedCues)
            if let attachmentID = audioPlayback.activeAudioAttachmentID {
                do {
                    try NotesAudioStore.shared.saveCues(updatedCues, attachmentID: attachmentID)
                } catch {
                    print("[ReadView] saving converted cues failed: \(error.localizedDescription)")
                }
            }
        }
        if audioPlayback.audioAttachmentCues.isEmpty == false {
            audioPlayback.audioAttachmentHighlightRanges = SubtitleParser.resolveHighlightRanges(
                for: audioPlayback.audioAttachmentCues, in: text
            )
        }
    }

    // The attached song's cues with each accepted proposal applied to the cue whose note line holds
    // it, word timings kept (CueTextReplacement). `proposals` must run last-first so earlier offsets
    // in a shared cue stay valid. nil when the note has no cues or nothing in them changed.
    private func convertedCues(for proposals: [TextConversion]) -> [SubtitleCue]? {
        var cues = audioPlayback.audioAttachmentCues
        let ranges = audioPlayback.audioAttachmentHighlightRanges
        guard cues.isEmpty == false else { return nil }
        var changed = false
        for proposal in proposals {
            guard let i = ranges.firstIndex(where: { $0.map { NSLocationInRange(proposal.range.location, $0) } == true }),
                  i < cues.count, let lineRange = ranges[i] else { continue }
            let cueText = cues[i].text as NSString
            // The cue normally matches its note line character for character; if it doesn't, fall
            // back to the English wherever it appears in the cue.
            var local = NSRange(location: proposal.range.location - lineRange.location, length: proposal.range.length)
            if NSMaxRange(local) > cueText.length || cueText.substring(with: local) != proposal.original {
                local = cueText.range(of: proposal.original)
            }
            guard local.location != NSNotFound,
                  let updated = CueTextReplacement.replacing(local, with: proposal.replacement, in: cues[i]) else { continue }
            cues[i] = updated
            changed = true
        }
        return changed ? cues : nil
    }
}
