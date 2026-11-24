import Foundation

// Keeps the saved alignment's own copy of each lyric line in step with plain edits to the note's
// text. The lyrics view shows other lines from the cues' text, so a line the user rewrote in the
// note (dropping a reading in parentheses, fixing a word) would otherwise keep showing its old
// wording there. Text conversions already do this for their own edits (ReadView+TextConversion).
extension ReadView {
    // Applies the note edit `oldText` → `newText` to the cue whose line holds it, word timings kept
    // (CueTextReplacement), and saves the cues. Only a replacement or deletion inside one line is
    // followed: an insertion has no old text to find in the cue, and an edit across lines isn't
    // attributable to one cue.
    func syncCueText(from oldText: String, to newText: String) {
        var cues = audioPlayback.audioAttachmentCues
        let ranges = audioPlayback.audioAttachmentHighlightRanges
        guard cues.isEmpty == false, let edit = CueTextReplacement.singleEdit(from: oldText, to: newText),
              edit.range.length > 0, edit.range.length <= 200,
              edit.replacement.contains(where: \.isNewline) == false else { return }
        let removed = (oldText as NSString).substring(with: edit.range)
        guard removed.contains(where: \.isNewline) == false,
              let index = ranges.firstIndex(where: { $0.map { NSLocationInRange(edit.range.location, $0) } == true }),
              index < cues.count, let lineRange = ranges[index] else { return }
        let cueText = cues[index].text as NSString
        // The cue normally matches its note line character for character; if it doesn't, the
        // removed text is used wherever it appears in the cue, but only when it appears once.
        var local = NSRange(location: edit.range.location - lineRange.location, length: edit.range.length)
        if NSMaxRange(local) > cueText.length || cueText.substring(with: local) != removed {
            local = cueText.range(of: removed)
            guard local.location != NSNotFound,
                  cueText.range(of: removed, range: NSRange(location: NSMaxRange(local), length: cueText.length - NSMaxRange(local))).location == NSNotFound
            else { return }
        }
        guard let updated = CueTextReplacement.replacing(local, with: edit.replacement, in: cues[index]) else { return }
        cues[index] = updated
        audioPlayback.audioAttachmentCues = cues
        audioPlayback.audioController.updateCues(cues)
        audioPlayback.audioAttachmentHighlightRanges = SubtitleParser.resolveHighlightRanges(for: cues, in: newText)
        guard let attachmentID = audioPlayback.activeAudioAttachmentID else { return }
        do {
            try NotesAudioStore.shared.saveCues(cues, attachmentID: attachmentID)
        } catch {
            AppLog.error(.storage, "[ReadView] saving cues after a note edit failed: \(error.localizedDescription)")
        }
    }
}
