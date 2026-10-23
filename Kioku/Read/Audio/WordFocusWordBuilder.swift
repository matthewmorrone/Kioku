import Foundation

// Flattens a song's cues into the ordered word list the word-focus view steps through. Pure
// projection of the note's persisted segmentation, furigana and the cues' timings; nothing here is
// stored.
enum WordFocusWordBuilder {
    // Every word of every sung cue, in order, with its start time. Words come from the note's
    // segmentation inside each cue's span (the span the lyrics card draws, clipped at the first
    // newline); punctuation carries none, and each non-speech (♪) cue is one interlude stop, as the
    // lyrics card shows it. Segments lying inside one of `wordRanges` (the song breakdown's words,
    // placed in the note) join into one stop, so a word the breakdown treats as one (のような, 夜の帳)
    // is one stop with one meaning rather than pieces that each borrow it. Start times never run
    // backwards, so the word playing is always the last one started.
    static func words(
        cues: [SubtitleCue],
        highlightRanges: [NSRange?],
        noteText: String,
        segmentationRanges: [Range<String.Index>],
        furiganaBySegmentLocation: [Int: String],
        furiganaLengthBySegmentLocation: [Int: Int],
        wordRanges: [NSRange] = []
    ) -> [WordFocusWord] {
        let note = noteText as NSString
        let segments = segmentationRanges.map { NSRange($0, in: noteText) }.filter { $0.location != NSNotFound && $0.length > 0 }
        var words: [WordFocusWord] = []
        var lastStartMs = 0
        for (index, cue) in cues.enumerated() {
            if SubtitleParser.isNonSpeechCue(cue.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let startMs = max(lastStartMs, cue.startMs)
                lastStartMs = startMs
                words.append(WordFocusWord(
                    id: -(index + 1),
                    surface: "",
                    pieces: [],
                    startMs: startMs,
                    interludeDurationMs: cue.endMs - cue.startMs
                ))
                continue
            }
            guard let span = cueSpan(at: index, cue: cue, highlightRanges: highlightRanges, note: note) else { continue }
            let checkpoints = LyricWordTiming.sortedCheckpoints(cue)
            var cursor = firstSegment(endingAfter: span.location, in: segments)
            while cursor < segments.count, segments[cursor].location < NSMaxRange(span) {
                let clipped = NSIntersectionRange(segments[cursor], span)
                cursor += 1
                guard clipped.length > 0 else { continue }
                let surface = note.substring(with: clipped)
                guard surface.contains(where: \.isLetter) else { continue }
                // The same sung time the lyrics card's bubbles use, last words brought forward included.
                let sungMs = max(lastStartMs, LyricWordTiming.startMs(
                    localOffset: clipped.location - span.location,
                    spanLength: span.length,
                    cue: cue,
                    checkpoints: checkpoints
                ))
                lastStartMs = sungMs
                words.append(WordFocusWord(
                    id: clipped.location,
                    surface: surface,
                    pieces: pieces(
                        of: clipped,
                        in: note,
                        furigana: furiganaBySegmentLocation,
                        furiganaLengths: furiganaLengthBySegmentLocation
                    ),
                    startMs: sungMs
                ))
            }
        }
        return joined(words, within: wordRanges)
    }

    // Joins runs of consecutive words that all sit inside the same range of `wordRanges` into one
    // word: its spelling and pieces in order, the first one's place in the note and start time.
    // Interlude stops and words outside every range are left as they are.
    private static func joined(_ words: [WordFocusWord], within wordRanges: [NSRange]) -> [WordFocusWord] {
        guard wordRanges.isEmpty == false else { return words }
        // The range holding a word wholly, if any.
        func container(of word: WordFocusWord) -> NSRange? {
            guard word.interludeDurationMs == nil else { return nil }
            let range = NSRange(location: word.id, length: (word.surface as NSString).length)
            return wordRanges.first { NSIntersectionRange($0, range) == range }
        }
        var result: [WordFocusWord] = []
        var runContainer: NSRange?
        for word in words {
            let wordContainer = container(of: word)
            if let wordContainer, wordContainer == runContainer, let previous = result.last {
                result[result.count - 1] = WordFocusWord(
                    id: previous.id,
                    surface: previous.surface + word.surface,
                    pieces: previous.pieces + word.pieces,
                    startMs: previous.startMs
                )
            } else {
                result.append(word)
            }
            runContainer = wordContainer
        }
        return result
    }

    // The cue's range in the note: its resolved highlight range, else where its text appears
    // verbatim, clipped at the first newline. Nil when the note doesn't hold it.
    private static func cueSpan(at index: Int, cue: SubtitleCue, highlightRanges: [NSRange?], note: NSString) -> NSRange? {
        var range: NSRange?
        if index < highlightRanges.count, let resolved = highlightRanges[index] {
            range = resolved
        } else if cue.text.isEmpty == false {
            let probe = note.range(of: cue.text)
            range = probe.location == NSNotFound ? nil : probe
        }
        guard let range, NSMaxRange(range) <= note.length else { return nil }
        let newline = note.rangeOfCharacter(from: .newlines, options: [], range: range)
        return newline.location == NSNotFound ? range : NSRange(location: range.location, length: newline.location - range.location)
    }

    // The index of the first segment ending after `location`, by bisection over the ascending segments.
    private static func firstSegment(endingAfter location: Int, in segments: [NSRange]) -> Int {
        var low = 0
        var high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(segments[mid]) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // The word split into runs: each furigana entry that starts inside it covers its kanji run, and
    // the text between runs is plain.
    private static func pieces(of word: NSRange, in note: NSString, furigana: [Int: String], furiganaLengths: [Int: Int]) -> [WordFocusPiece] {
        var pieces: [WordFocusPiece] = []
        var location = word.location
        while location < NSMaxRange(word) {
            if let reading = furigana[location], reading.isEmpty == false {
                let length = min(max(furiganaLengths[location] ?? 1, 1), NSMaxRange(word) - location)
                pieces.append(WordFocusPiece(base: note.substring(with: NSRange(location: location, length: length)), ruby: reading))
                location += length
            } else {
                var end = location + 1
                while end < NSMaxRange(word), furigana[end] == nil { end += 1 }
                pieces.append(WordFocusPiece(base: note.substring(with: NSRange(location: location, length: end - location)), ruby: nil))
                location = end
            }
        }
        return pieces
    }
}
