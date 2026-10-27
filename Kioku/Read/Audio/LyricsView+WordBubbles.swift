import SwiftUI

// Word bubbles on the lyrics card's active line, in place of a line translation: as each word is
// sung, a speech bubble with its meaning pops up beside the line pointing at it. Meanings come from the breakdown
// when it covers the line (its in-context definitions), else
// from the dictionary through dictionaryGloss, which the Read view supplies so no lexical lookup
// happens here. Drawn by LyricWordBubbleOverlay; shown while the Bubbles setting is on, and
// each kind of word (particles, katakana loanwords, katakana words) only while its option in
// the Bubbles menu is on. Words written in Latin letters never get one.
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
        hasher.combine(showsLoanwordBubbles)
        hasher.combine(showsKatakanaBubbles)
        hasher.combine(showsVocalizationBubbles)
        let signature = hasher.finalize()
        if wordBubbleCache.signature == signature { return wordBubbleCache.bubbles }
        let bubbles = breakdownPlacement.flatMap { breakdownWordBubbles($0, in: cueSpan) }
            ?? dictionaryWordBubbles(in: cueSpan)
        wordBubbleCache.signature = signature
        wordBubbleCache.bubbles = bubbles
        return bubbles
    }

    // The breakdown line covering the cue (SongBreakdownPlacement), its words in the cue each with
    // its definition in the speech bubble, minus the kinds of word the shared filters hide — the
    // same SongWordVisibility rule the Breakdown's cards and listen-along use. The line's
    // pattern-to-bank note stays out: bubbles hold meanings only. Nil when no breakdown line covers
    // the cue or none of its words could be found in it.
    private func breakdownWordBubbles(_ placement: SongBreakdownPlacement, in cueRange: NSRange) -> [LyricWordBubble]? {
        guard let line = placement.line(overlapping: cueRange) else { return nil }
        let filter = meaningFilter
        var bubbles: [LyricWordBubble] = []
        for placed in line.words {
            guard NSIntersectionRange(placed.range, cueRange).length > 0, filter.allows(breakdownWord: placed.word) else { continue }
            bubbles.append(LyricWordBubble(noteRange: placed.range, gloss: Self.shortGloss(placed.word.definition)))
        }
        return bubbles.isEmpty ? nil : bubbles
    }

    // The cue's segments, each with its dictionary meaning (none for anything the dictionary
    // doesn't know, which dictionaryGloss returns nil for, nor for particles while their bubbles
    // are off).
    private func dictionaryWordBubbles(in cueRange: NSRange) -> [LyricWordBubble] {
        guard let dictionaryGloss else { return [] }
        let filter = meaningFilter
        return segmentationRanges.compactMap { range in
            let nsRange = NSRange(range, in: noteText)
            guard nsRange.length > 0, NSIntersectionRange(nsRange, cueRange).length > 0 else { return nil }
            let surface = String(noteText[range])
            guard filter.allows(dictionaryWord: surface, at: nsRange.location),
                  let gloss = dictionaryGloss(nsRange.location, surface) else { return nil }
            return LyricWordBubble(noteRange: nsRange, gloss: Self.shortGloss(gloss))
        }
    }

    // Which words get a bubble: the shared lyric-word filter, from this card's toggles and the
    // Read view's particle and loanword checks.
    private var meaningFilter: LyricWordMeaningFilter {
        LyricWordMeaningFilter(
            showsParticles: showsParticleBubbles,
            showsKatakana: showsKatakanaBubbles,
            showsVocalizations: showsVocalizationBubbles,
            showsLoanwords: showsLoanwordBubbles,
            isParticle: isParticle,
            isLoanword: isLoanword
        )
    }

    // A meaning short enough for a bubble: its first sense, up to the first semicolon or comma —
    // a breakdown's loanword definition runs on after it ("search, from English search") — with its
    // parenthetical qualifiers left out ("caramel (confectionery)" says "caramel", "light (from
    // French 'lumière')" says "light"). Nil when nothing is left.
    static func shortGloss(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: { ";,".contains($0) }).first.map(String.init) else { return nil }
        var gloss = ""
        var depth = 0
        for character in first {
            if "(（".contains(character) { depth += 1 } else if ")）".contains(character) { depth = max(0, depth - 1) } else if depth == 0 { gloss.append(character) }
        }
        return nonEmpty(gloss)
    }

    // The text trimmed, or nil when nothing is left.
    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    // When a word's bubble appears: when it's sung, brought forward to the line's deadline at the
    // latest (LyricWordTiming, the rule the full-screen word view follows too).
    private func wordStartMs(_ bubble: LyricWordBubble, cueAt index: Int, cueSpan: NSRange) -> Int {
        guard index < cues.count else { return 0 }
        let cue = cues[index]
        return LyricWordTiming.startMs(
            localOffset: bubble.noteRange.location - cueSpan.location,
            spanLength: cueSpan.length,
            cue: cue,
            checkpoints: LyricWordTiming.sortedCheckpoints(cue)
        )
    }

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
            waitMs = min(waitMs, max(0, LyricWordTiming.deadlineMs(for: cues[line]) - controller.currentTimeMs))
        }
        try? await Task.sleep(for: .milliseconds(waitMs))
        guard Task.isCancelled == false else { return }
        settledBubbleLine = line
    }
}
