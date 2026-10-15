import SwiftUI

// Word bubbles on the lyrics card's active line, in place of a line translation: as each word is
// sung, a speech bubble with its meaning pops up above it and, where the song breakdown has a note
// on it, a thought bubble below. Meanings come from the breakdown when it covers the line (its
// in-context definitions and grammar tags, plus the line's grammar note on the last word), else
// from the dictionary through dictionaryGloss, which the Read view supplies so no lexical lookup
// happens here. Drawn by LyricWordBubbleOverlay; shown while the Translation setting is on.
extension LyricsView {
    // The cue's words with their bubble text, built once per line (wordBubbleCache).
    func wordBubbles(forCueAt index: Int) -> [LyricWordBubble] {
        guard index < highlightRanges.count, let cueRange = highlightRanges[index], cueRange.length > 0 else { return [] }
        let breakdown = noteID.flatMap { songBreakdownStore.breakdown(forNoteID: $0) }
        var hasher = Hasher()
        hasher.combine(cueRange.location)
        hasher.combine(cueRange.length)
        hasher.combine(breakdown?.generatedAt)
        hasher.combine(noteText.utf16.count)
        hasher.combine(segmentationRanges.count)
        let signature = hasher.finalize()
        if wordBubbleCache.signature == signature { return wordBubbleCache.bubbles }
        let bubbles = breakdown.flatMap { breakdownWordBubbles($0.lines, in: cueRange) }
            ?? dictionaryWordBubbles(in: cueRange)
        wordBubbleCache.signature = signature
        wordBubbleCache.bubbles = bubbles
        return bubbles
    }

    // The breakdown line covering the cue, its words found in the note in order: the definition in
    // the speech bubble (none for particles and vocalizations, whose tag says enough), the grammar
    // tag in the thought bubble, and the line's grammar note added to the last word's. Nil when no
    // breakdown line covers the cue or none of its words could be found in it.
    private func breakdownWordBubbles(_ lines: [SongLine], in cueRange: NSRange) -> [LyricWordBubble]? {
        let lineRanges = SongBreakdownLineLocator.noteRanges(for: lines, in: noteText)
        guard let line = lines.first(where: { lineRanges[$0.index].map { NSIntersectionRange($0, cueRange).length > 0 } ?? false }),
              let lineRange = lineRanges[line.index] else { return nil }
        let note = noteText as NSString
        var cursor = lineRange.location
        var bubbles: [LyricWordBubble] = []
        for word in line.words {
            let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard surface.isEmpty == false, cursor < NSMaxRange(lineRange) else { continue }
            let found = note.range(of: surface, options: [], range: NSRange(location: cursor, length: NSMaxRange(lineRange) - cursor))
            guard found.location != NSNotFound else { continue }
            cursor = NSMaxRange(found)
            guard NSIntersectionRange(found, cueRange).length > 0 else { continue }
            let tag = Self.nonEmpty(word.grammarTag)
            let isFunctionWord = tag == "particle" || tag == "vocalization"
            bubbles.append(LyricWordBubble(
                noteRange: found,
                gloss: isFunctionWord ? nil : Self.shortGloss(word.definition),
                comment: tag
            ))
        }
        if let grammarNote = Self.nonEmpty(line.grammarNote),
           let last = bubbles.indices.last {
            let word = bubbles[last]
            bubbles[last] = LyricWordBubble(
                noteRange: word.noteRange,
                gloss: word.gloss,
                comment: [word.comment, grammarNote].compactMap { $0 }.joined(separator: " — ")
            )
        }
        return bubbles.isEmpty ? nil : bubbles
    }

    // The cue's segments, each with its dictionary meaning (none for particles and anything the
    // dictionary doesn't know, which dictionaryGloss returns nil for).
    private func dictionaryWordBubbles(in cueRange: NSRange) -> [LyricWordBubble] {
        guard let dictionaryGloss else { return [] }
        return segmentationRanges.compactMap { range in
            let nsRange = NSRange(range, in: noteText)
            guard nsRange.length > 0, NSIntersectionRange(nsRange, cueRange).length == nsRange.length else { return nil }
            let surface = String(noteText[range])
            guard surface.contains(where: \.isLetter), let gloss = dictionaryGloss(nsRange.location, surface) else { return nil }
            return LyricWordBubble(noteRange: nsRange, gloss: Self.shortGloss(gloss), comment: nil)
        }
    }

    // A meaning short enough for a bubble: its first sense up to the first semicolon.
    static func shortGloss(_ text: String) -> String? {
        nonEmpty(text.split(separator: ";").first.map(String.init))
    }

    // The text trimmed, or nil when nothing is left.
    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    // When a word is sung: the first karaoke checkpoint reaching its first character, else its
    // share of the cue's span when the cue has no checkpoints.
    private func wordStartMs(_ bubble: LyricWordBubble, cueAt index: Int) -> Int {
        guard index < cues.count, index < highlightRanges.count, let cueRange = highlightRanges[index] else { return 0 }
        let cue = cues[index]
        let local = bubble.noteRange.location - cueRange.location
        let checkpoints = cue.checkpoints.sorted { $0.charOffsetInCue < $1.charOffsetInCue }
        if let hit = checkpoints.first(where: { $0.charOffsetInCue + max($0.charLength, 1) > local }) {
            return hit.timeMs
        }
        if let last = checkpoints.last { return last.timeMs }
        return cue.startMs + (cue.endMs - cue.startMs) * max(0, local) / max(1, cueRange.length)
    }

    // The cue-local ranges of the cue's words, plus the whole line (for the room beside it), for
    // the renderer to measure.
    func wordBubbleRanges(forCueAt index: Int, cueOriginInNote: Int, cueLength: Int) -> [NSRange] {
        let words = wordBubbles(forCueAt: index).compactMap { bubble -> NSRange? in
            let local = NSRange(location: bubble.noteRange.location - cueOriginInNote, length: bubble.noteRange.length)
            return local.location >= 0 && NSMaxRange(local) <= cueLength ? local : nil
        }
        guard words.isEmpty == false, cueLength > 0 else { return [] }
        return words + [NSRange(location: 0, length: cueLength)]
    }

    // The measured rect of the whole active line, once the renderer has reported it.
    func wordBubbleLineRect(cueLength: Int) -> CGRect? {
        wordBubbleRects[NSRange(location: 0, length: cueLength)]
    }

    // The bubbles to draw now: on the line being played, the words sung so far; on a line the user
    // has dragged into view, all of them. Each placed at its word's measured rect.
    func placedWordBubbles(forCueAt index: Int, cueOriginInNote: Int, cueLength: Int) -> [PlacedLyricWordBubble] {
        let isLive = index == activeIndex
        let now = controller.currentTimeMs
        return wordBubbles(forCueAt: index).compactMap { bubble in
            if isLive, wordStartMs(bubble, cueAt: index) > now { return nil }
            let local = NSRange(location: bubble.noteRange.location - cueOriginInNote, length: bubble.noteRange.length)
            guard let rect = wordBubbleRects[local] else { return nil }
            return PlacedLyricWordBubble(id: bubble.noteRange.location, anchor: rect, gloss: bubble.gloss, comment: bubble.comment)
        }
    }
}
