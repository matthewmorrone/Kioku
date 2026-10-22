import SwiftUI

// Word bubbles on the lyrics card's active line, in place of a line translation: as each word is
// sung, a speech bubble with its meaning pops up beside the line pointing at it. Meanings come from the breakdown
// when it covers the line (its in-context definitions), else
// from the dictionary through dictionaryGloss, which the Read view supplies so no lexical lookup
// happens here. Drawn by LyricWordBubbleOverlay; shown while the Bubbles setting is on, and
// each kind of word only while its option in the Bubbles menu is on.
extension LyricsView {
    // The words of the text the card shows for a cue (`cueSpan`, in note coordinates — the same
    // span the renderer draws, so no word at its edges is lost to a slightly different cue range)
    // with their bubble text, built once per line (wordBubbleCache).
    func wordBubbles(in cueSpan: NSRange) -> [LyricWordBubble] {
        guard cueSpan.length > 0, NSMaxRange(cueSpan) <= (noteText as NSString).length else { return [] }
        let breakdown = noteID.flatMap { songBreakdownStore.breakdown(forNoteID: $0) }
        var hasher = Hasher()
        hasher.combine(cueSpan.location)
        hasher.combine(cueSpan.length)
        hasher.combine(breakdown?.generatedAt)
        hasher.combine(noteText.utf16.count)
        hasher.combine(segmentationRanges.count)
        hasher.combine(showsParticleBubbles)
        let signature = hasher.finalize()
        if wordBubbleCache.signature == signature { return wordBubbleCache.bubbles }
        let bubbles = breakdown.flatMap { breakdownWordBubbles($0.lines, in: cueSpan) }
            ?? dictionaryWordBubbles(in: cueSpan)
        wordBubbleCache.signature = signature
        wordBubbleCache.bubbles = bubbles
        return bubbles
    }

    // The breakdown line covering the cue, its words found in the note in order, each with its
    // definition in the speech bubble — vocalizations too, and particles (tagged `[particle]`, or in
    // older breakdowns a single-kana particle, as SongWordVisibility counts them) unless their
    // bubbles are turned off. The line's
    // pattern-to-bank note stays out: bubbles hold meanings only. Nil when no breakdown line
    // covers the cue or none of its words could be found in it.
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
            // Punctuation (a "（" the model was asked to gloss) is no word and gets no bubble.
            guard NSIntersectionRange(found, cueRange).length > 0, surface.contains(where: \.isLetter) else { continue }
            let isParticle = word.grammarTag?.lowercased() == SongWordVisibility.particleTag || KanaData.particleSet.contains(surface)
            if isParticle, showsParticleBubbles == false { continue }
            bubbles.append(LyricWordBubble(noteRange: found, gloss: Self.shortGloss(word.definition)))
        }
        return bubbles.isEmpty ? nil : bubbles
    }

    // The cue's segments, each with its dictionary meaning (none for anything the dictionary
    // doesn't know, which dictionaryGloss returns nil for, nor for particles while their bubbles
    // are off).
    private func dictionaryWordBubbles(in cueRange: NSRange) -> [LyricWordBubble] {
        guard let dictionaryGloss else { return [] }
        return segmentationRanges.compactMap { range in
            let nsRange = NSRange(range, in: noteText)
            guard nsRange.length > 0, NSIntersectionRange(nsRange, cueRange).length > 0 else { return nil }
            let surface = String(noteText[range])
            guard surface.contains(where: \.isLetter),
                  showsParticleBubbles || isParticle?(nsRange.location, surface) != true,
                  let gloss = dictionaryGloss(nsRange.location, surface) else { return nil }
            return LyricWordBubble(noteRange: nsRange, gloss: Self.shortGloss(gloss))
        }
    }

    // A meaning short enough for a bubble: its first sense, up to the first semicolon or comma —
    // a breakdown's loanword definition runs on after it ("search, from English search"). Nil
    // when it carries a parenthetical ("to become (a state)", "dear (term of address)"): a gloss
    // that needs qualifying is too much for a bubble and usually the wrong sense for the line anyway.
    static func shortGloss(_ text: String) -> String? {
        guard let gloss = nonEmpty(text.split(whereSeparator: { ";,".contains($0) }).first.map(String.init)),
              gloss.contains(where: { "()（）".contains($0) }) == false else { return nil }
        return gloss
    }

    // The text trimmed, or nil when nothing is left.
    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    // When a word's bubble appears: when it's sung — the first karaoke checkpoint reaching its
    // first character, else its share of the cue's span when the cue has no checkpoints — but no
    // later than bubbleDeadlineMs, so a word timed at the line's very end (or past it, from a late
    // alignment) still gets its bubble before the card moves on.
    private func wordStartMs(_ bubble: LyricWordBubble, cueAt index: Int, cueSpan: NSRange) -> Int {
        guard index < cues.count else { return 0 }
        let cue = cues[index]
        let local = bubble.noteRange.location - cueSpan.location
        let checkpoints = cue.checkpoints.sorted { $0.charOffsetInCue < $1.charOffsetInCue }
        let sungMs: Int
        if let hit = checkpoints.first(where: { $0.charOffsetInCue + max($0.charLength, 1) > local }) {
            sungMs = hit.timeMs
        } else if let last = checkpoints.last {
            sungMs = last.timeMs
        } else {
            sungMs = cue.startMs + (cue.endMs - cue.startMs) * max(0, local) / max(1, cueSpan.length)
        }
        return min(sungMs, bubbleDeadlineMs(forCueAt: index))
    }

    // The latest a line's bubbles may appear: bubbleLeadMs before the cue ends (when the card moves
    // to the next line), and never before the cue starts — a line shorter than that shows every
    // bubble at once.
    private func bubbleDeadlineMs(forCueAt index: Int) -> Int {
        let cue = cues[index]
        return max(cue.startMs, cue.endMs - Self.bubbleLeadMs)
    }

    // How long the last bubbles of a line stay up, at least, before the card moves on.
    static let bubbleLeadMs = 400

    // A word's range in the card's text, clipped to it (a word straddling the cue's edge keeps its
    // visible part).
    private func cueLocalRange(_ bubble: LyricWordBubble, cueSpan: NSRange) -> NSRange? {
        let clipped = NSIntersectionRange(bubble.noteRange, cueSpan)
        guard clipped.length > 0 else { return nil }
        return NSRange(location: clipped.location - cueSpan.location, length: clipped.length)
    }

    // The cue-local ranges of the cue's words, plus the whole line (for the room beside it), for
    // the renderer to measure.
    func wordBubbleRanges(forCueAt index: Int, cueOriginInNote: Int, cueLength: Int) -> [NSRange] {
        let cueSpan = NSRange(location: cueOriginInNote, length: cueLength)
        let words = wordBubbles(in: cueSpan).compactMap { cueLocalRange($0, cueSpan: cueSpan) }
        guard words.isEmpty == false else { return [] }
        return words + [NSRange(location: 0, length: cueLength)]
    }

    // The measured rect of the whole active line, once the renderer has reported it.
    func wordBubbleLineRect(cueLength: Int) -> CGRect? {
        wordBubbleRects[NSRange(location: 0, length: cueLength)]
    }

    // All the line's bubbles, each placed at its word's measured rect, so the overlay lays out the
    // whole line at once and none moves as more appear. Shown: on the line being played, the words
    // sung so far; on a line the user has dragged into view, all of them.
    func placedWordBubbles(forCueAt index: Int, cueOriginInNote: Int, cueLength: Int) -> [PlacedLyricWordBubble] {
        let cueSpan = NSRange(location: cueOriginInNote, length: cueLength)
        let isLive = index == activeIndex
        let now = controller.currentTimeMs
        return wordBubbles(in: cueSpan).compactMap { bubble in
            guard let local = cueLocalRange(bubble, cueSpan: cueSpan), let rect = wordBubbleRects[local] else { return nil }
            let isSung = isLive == false || wordStartMs(bubble, cueAt: index, cueSpan: cueSpan) <= now
            return PlacedLyricWordBubble(
                id: bubble.noteRange.location,
                anchor: rect,
                gloss: bubble.gloss,
                isShown: isSung
            )
        }
    }

    // Shows the bubbles on `line` once the card has stayed there a moment, and hides them while the
    // lines are being dragged or scrubbed through; a cancelled wait (the line moved on) shows nothing.
    // On the line being played the wait ends by its bubble deadline, so a short line still shows
    // its bubbles before the card moves on.
    func settleWordBubbles(on line: Int, isMoving: Bool) async {
        settledBubbleLine = nil
        guard isMoving == false else { return }
        var waitMs = 350
        if line == activeIndex, line < cues.count {
            waitMs = min(waitMs, max(0, bubbleDeadlineMs(forCueAt: line) - controller.currentTimeMs))
        }
        try? await Task.sleep(for: .milliseconds(waitMs))
        guard Task.isCancelled == false else { return }
        settledBubbleLine = line
    }
}
