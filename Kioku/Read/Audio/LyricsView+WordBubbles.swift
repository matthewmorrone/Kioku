import SwiftUI

// Word bubbles on the lyrics card's active line, in place of a line translation: as each word is
// sung, a speech bubble with its meaning pops up above or below the line pointing at it. Meanings come from the breakdown
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
        hasher.combine(glossRevision)
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
    // same SongWordVisibility rule the Breakdown's cards use. Words of the cue the breakdown didn't
    // place (it names 手を取る where the note sings 手を取り, or leaves a word out) take their
    // dictionary meaning instead, as on a line with no breakdown. The line's pattern-to-bank note
    // stays out: bubbles hold meanings only. Nil when no breakdown line covers the cue or nothing
    // in it has a meaning.
    private func breakdownWordBubbles(_ placement: SongBreakdownPlacement, in cueRange: NSRange) -> [LyricWordBubble]? {
        guard let line = placement.line(overlapping: cueRange) else { return nil }
        let filter = meaningFilter
        // One bubble per segment the card shows, whatever the breakdown's own word boundaries are:
        // the breakdown splitting a segment in two, or running two segments together, must not
        // make two bubbles on one segment or one bubble over two.
        let segments = segmentationRanges.map { NSRange($0, in: noteText) }
            .filter { $0.length > 0 && NSIntersectionRange($0, cueRange).length > 0 }
        var bubbles: [LyricWordBubble] = []
        var covered: [NSRange] = []
        for segment in segments {
            // The breakdown word that overlaps this segment most, taken only when this segment is
            // also that word's best match (so a word spanning two segments serves one of them).
            let words = line.words.filter { NSIntersectionRange($0.range, segment).length > 0 }
            guard let placed = words.max(by: { NSIntersectionRange($0.range, segment).length < NSIntersectionRange($1.range, segment).length }),
                  segments.max(by: { NSIntersectionRange($0, placed.range).length < NSIntersectionRange($1, placed.range).length }) == segment
            else { continue }
            covered.append(segment)
            if filter.allows(breakdownWord: placed.word) {
                if let gloss = Self.bubbleText(for: placed.word.definition) {
                    bubbles.append(LyricWordBubble(noteRange: segment, gloss: gloss))
                }
            } else if let word = LyricWordMeaningFilter.singleWordMeaning(in: placed.word.definition),
                      filter.allows(breakdownWord: placed.word, gloss: word) {
                // A particle hidden by the toggle that still has a one-word meaning.
                bubbles.append(LyricWordBubble(noteRange: segment, gloss: word))
            }
        }
        // Segments the breakdown didn't place take their dictionary meaning.
        bubbles += dictionaryWordBubbles(in: cueRange, excluding: covered)
        bubbles.sort { $0.noteRange.location < $1.noteRange.location }
        return bubbles.isEmpty ? nil : bubbles
    }

    // The cue's segments, each with its dictionary meaning (none for anything the dictionary
    // doesn't know, which dictionaryGloss returns nil for, nor for particles while their bubbles
    // are off, unless the meaning is a single word like "with"), leaving out the segments inside `excluded` ranges (words the breakdown covers).
    private func dictionaryWordBubbles(in cueRange: NSRange, excluding excluded: [NSRange] = []) -> [LyricWordBubble] {
        guard let dictionaryGloss else { return [] }
        let filter = meaningFilter
        return segmentationRanges.compactMap { range in
            let nsRange = NSRange(range, in: noteText)
            guard nsRange.length > 0, NSIntersectionRange(nsRange, cueRange).length > 0,
                  excluded.contains(where: { NSIntersectionRange($0, nsRange).length > 0 }) == false else { return nil }
            let surface = String(noteText[range])
            guard let gloss = dictionaryGloss(nsRange.location, surface) else { return nil }
            if filter.allows(dictionaryWord: surface, at: nsRange.location) {
                return Self.bubbleText(for: gloss).map { LyricWordBubble(noteRange: nsRange, gloss: $0) }
            }
            // A particle hidden by the toggle that still has a one-word meaning.
            guard let word = LyricWordMeaningFilter.singleWordMeaning(in: gloss),
                  filter.allows(dictionaryWord: surface, at: nsRange.location, gloss: word) else { return nil }
            return LyricWordBubble(noteRange: nsRange, gloss: word)
        }
    }

    // Which words get a bubble: the shared lyric-word filter, from this card's toggles and the
    // Read view's particle and loanword checks.
    private var meaningFilter: LyricWordMeaningFilter {
        // TEMPORARY: the Particles, Katakana, Vocalizations and English Words filters are bypassed
        // while the inconsistency in which bubbles appear is tracked down. Particles whose meaning
        // only names a grammar role are still left out (see bubbleText).
        LyricWordMeaningFilter(
            showsParticles: true,
            showsKatakana: true,
            showsVocalizations: true,
            showsLoanwords: true,
            isParticle: isParticle,
            isLoanword: isLoanword
        )
    }

    // What a word's bubble says for its dictionary or breakdown meaning. A meaning that only names a
    // grammar role ("indicates the subject of a sentence", "nominalizes verbs") says nothing about
    // the word, so it gets no bubble, unless the meaning has a one-word alternative; the possessive
    // role reads as "of". Any other meaning is shortened (shortGloss). Nil when there is nothing to say.
    static func bubbleText(for definition: String) -> String? {
        switch LyricBubbleRules.verdict(for: definition) {
        case .replace(let text): return text
        case .hide: return LyricWordMeaningFilter.singleWordMeaning(in: definition)
        case .keep: break
        }
        return shortGloss(definition)
    }

    // A meaning short enough for a bubble: its first sense, up to the first semicolon or comma —
    // a breakdown's loanword definition runs on after it ("search, from English search") — with its
    // parenthetical qualifiers left out ("caramel (confectionery)" says "caramel", "light (from
    // French 'lumière')" says "light") — and only the first of its " or " alternatives ("surpassing or
    // crossing" says "surpassing"). Nil when nothing is left.
    static func shortGloss(_ text: String) -> String? {
        guard let firstSense = text.split(separator: ";").first else { return nil }
        // A run of single plain words ("one, two, three") is one meaning and stays whole; otherwise
        // the first comma-separated part is the meaning and the rest elaborates it.
        let parts = firstSense.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.isEmpty == false }
        guard let head = parts.first else { return nil }
        let isWordList = parts.count > 1 && parts.allSatisfy { $0.contains(where: \.isWhitespace) == false && $0.contains(where: { "()（）".contains($0) }) == false }
        let sense = isWordList ? parts.joined(separator: ", ") : head
        let first = sense.components(separatedBy: " or ").first ?? sense
        var gloss = ""
        var depth = 0
        for character in first {
            if "(（".contains(character) { depth += 1 } else if ")）".contains(character) { depth = max(0, depth - 1) } else if depth == 0 { gloss.append(character) }
        }
        // Removing a parenthetical leaves its surrounding spaces ("to hug (tightly) tight").
        return nonEmpty(gloss.split(whereSeparator: \.isWhitespace).joined(separator: " "))
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

    // The cue-local ranges of the cue's words, for the renderer to measure.
    func wordBubbleRanges(forCueAt index: Int, cueOriginInNote: Int, cueLength: Int) -> [NSRange] {
        let cueSpan = NSRange(location: cueOriginInNote, length: cueLength)
        let words = wordBubbles(in: cueSpan).compactMap { cueLocalRange($0, cueSpan: cueSpan) }
        guard words.isEmpty == false else { return [] }
        return words
    }

    // All the line's bubbles, each placed at its word's measured rect, so the overlay lays out the
    // whole line at once and none moves as more appear. Shown: on the line being played, the words
    // sung so far; on a line the user has dragged into view, or while playback is paused, all of them.
    func placedWordBubbles(forCueAt index: Int, cueOriginInNote: Int, cueLength: Int) -> [PlacedLyricWordBubble] {
        let cueSpan = NSRange(location: cueOriginInNote, length: cueLength)
        let isLive = index == activeIndex
        let now = controller.currentTimeMs
        return wordBubbles(in: cueSpan).compactMap { bubble in
            guard let local = cueLocalRange(bubble, cueSpan: cueSpan), let rect = wordBubbleRects[local] else { return nil }
            let isSung = isLive == false || controller.isPlaying == false || wordStartMs(bubble, cueAt: index, cueSpan: cueSpan) <= now
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
        // TEMPORARY: no settle delay.
        var waitMs = 0
        if line == activeIndex, line < cues.count {
            waitMs = min(waitMs, max(0, LyricWordTiming.deadlineMs(for: cues[line]) - controller.currentTimeMs))
        }
        try? await Task.sleep(for: .milliseconds(waitMs))
        guard Task.isCancelled == false else { return }
        settledBubbleLine = line
    }

    // Whether the word-bubble overlay is up on the active card for `index`, and so draws the
    // translation line itself in front of the bubbles' tails. False for interlude rows, which have
    // no overlay.
    func bubbleOverlayDrawsTranslation(at index: Int) -> Bool {
        guard showsBubbles, settledBubbleLine == index else { return false }
        return (index < cues.count && isNonSpeechCue(at: index)) == false
    }
}
