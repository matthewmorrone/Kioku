import Foundation

// Flattens a song's cues into the ordered word list the word-focus view steps through. Pure
// projection of the note's persisted segmentation, furigana and the cues' timings; nothing here is
// stored.
enum WordFocusWordBuilder {
    // Every word of every sung cue, in order, with its start time. Words come from the note's
    // segmentation inside each cue's span (the span the lyrics card draws, clipped at the first
    // newline); punctuation and non-speech cues carry none. Start times never run backwards, so the
    // word playing is always the last one started.
    static func words(
        cues: [SubtitleCue],
        highlightRanges: [NSRange?],
        noteText: String,
        segmentationRanges: [Range<String.Index>],
        furiganaBySegmentLocation: [Int: String],
        furiganaLengthBySegmentLocation: [Int: Int]
    ) -> [WordFocusWord] {
        let note = noteText as NSString
        let segments = segmentationRanges.map { NSRange($0, in: noteText) }.filter { $0.location != NSNotFound && $0.length > 0 }
        var words: [WordFocusWord] = []
        var lastStartMs = 0
        for (index, cue) in cues.enumerated() {
            guard SubtitleParser.isNonSpeechCue(cue.text.trimmingCharacters(in: .whitespacesAndNewlines)) == false,
                  let span = cueSpan(at: index, cue: cue, highlightRanges: highlightRanges, note: note) else { continue }
            let checkpoints = cue.checkpoints.sorted { $0.charOffsetInCue < $1.charOffsetInCue }
            var cursor = firstSegment(endingAfter: span.location, in: segments)
            while cursor < segments.count, segments[cursor].location < NSMaxRange(span) {
                let clipped = NSIntersectionRange(segments[cursor], span)
                cursor += 1
                guard clipped.length > 0 else { continue }
                let surface = note.substring(with: clipped)
                guard surface.contains(where: \.isLetter) else { continue }
                let sungMs = max(lastStartMs, startMs(of: clipped, in: span, cue: cue, checkpoints: checkpoints))
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
        return words
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

    // When a word is sung: the first karaoke checkpoint reaching its first character, else the
    // cue's last checkpoint, else its share of the cue's span.
    private static func startMs(of word: NSRange, in span: NSRange, cue: SubtitleCue, checkpoints: [CueCharTiming]) -> Int {
        let local = word.location - span.location
        if let hit = checkpoints.first(where: { $0.charOffsetInCue + max($0.charLength, 1) > local }) { return hit.timeMs }
        if let last = checkpoints.last { return last.timeMs }
        return cue.startMs + (cue.endMs - cue.startMs) * max(0, local) / max(1, span.length)
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
