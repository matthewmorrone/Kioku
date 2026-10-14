import Foundation

// Moves between the open note's three views of the same line: the Read text, the lyrics view and
// the breakdown sheet. Backs ReadNoteTarget destinations (a word's source note in Word Detail, the
// breakdown's "Open in Lyrics", a random breakdown), and the lyrics view's breakdown button. Every
// path speaks in note-text UTF-16 locations, so a line maps to a lyric cue through the cue's
// highlight range and to a breakdown line through SongBreakdownLineLocator.
extension ReadView {
    // Where in the note a target points: its pinned location when it has one, else the first
    // occurrence of its surface, else nil (the destination opens wherever it was).
    func noteLocation(for target: ReadNoteTarget) -> Int? {
        let length = (document.text as NSString).length
        if let location = target.noteLocation, location >= 0, location <= length {
            return location
        }
        guard target.surface.isEmpty == false, let range = document.text.range(of: target.surface) else {
            return nil
        }
        return NSRange(range, in: document.text).location
    }

    // Opens the lyrics view seeked to the cue holding `location`, or the breakdown sheet scrolled
    // to the line holding it. Each closes the other, so the user lands on exactly one of them.
    func openNoteDestination(_ destination: ReadNoteDestination, atNoteLocation location: Int?) {
        SegmentLookupSheet.shared.dismissPopover()
        switch destination {
        case .text:
            return
        case .lyrics:
            readSheets.isShowingBreakdownSheet = false
            guard audioPlayback.activeAudioAttachmentID != nil else {
                AppLog.info(.audioPlayback, "[ReadView] lyrics requested for a note with no audio")
                return
            }
            if let location, let cueIndex = cueIndex(forNoteLocation: location) {
                audioPlayback.audioController.seek(toMs: audioPlayback.audioAttachmentCues[cueIndex].startMs)
            }
            audioPlayback.isShowingLyricsView = true
        case .breakdown:
            readSheets.breakdownFocusLocation = location
            readSheets.isShowingBreakdownSheet = true
        }
    }

    // The lyric cue covering a note location: the cue whose highlight range holds it, else one
    // overlapping its line, else (cues the alignment didn't place in the note) one whose text is
    // that line's.
    func cueIndex(forNoteLocation location: Int) -> Int? {
        let cues = audioPlayback.audioAttachmentCues
        let ranges = audioPlayback.audioAttachmentHighlightRanges
        let text = document.text as NSString
        guard cues.isEmpty == false, location >= 0, location <= text.length else { return nil }
        let placed = cues.indices.compactMap { index -> (index: Int, range: NSRange)? in
            guard index < ranges.count, let range = ranges[index] else { return nil }
            return (index, range)
        }
        if let exact = placed.first(where: { NSLocationInRange(location, $0.range) }) {
            return exact.index
        }
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        if let overlapping = placed.first(where: { NSIntersectionRange(line, $0.range).length > 0 }) {
            return overlapping.index
        }
        let key = SongLineCueMatcher.normalize(text.substring(with: line))
        guard key.isEmpty == false else { return nil }
        return cues.firstIndex { SongLineCueMatcher.normalize($0.text) == key }
    }

    // The note location of the lyric line playing now, for the lyrics view's breakdown button:
    // the active cue's highlight range, else the first occurrence of its text. Nil before any cue
    // is active, which opens the breakdown wherever it was.
    func activeLyricNoteLocation() -> Int? {
        guard let index = audioPlayback.audioController.activeCueIndex else { return nil }
        let ranges = audioPlayback.audioAttachmentHighlightRanges
        if index < ranges.count, let range = ranges[index] {
            return range.location
        }
        let cues = audioPlayback.audioAttachmentCues
        guard index < cues.count else { return nil }
        let cueText = cues[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cueText.isEmpty == false, let found = document.text.range(of: cueText) else { return nil }
        return NSRange(found, in: document.text).location
    }
}
