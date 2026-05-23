import Foundation

// Heals SongBreakdowns produced before the parser's "implicit section boundary on **Line N:**"
// fix was in place. Those breakdowns collapsed every line of the song into line 1: the
// leaked headers + romaji ended up in `line[0].grammarNote` (with newlines flattened to
// spaces), and every line's bullets ended up concatenated in `line[0].words`.
//
// We can't recover the per-line gists/grammar/sungRomaji that were overwritten during the
// original parse, but we can:
//
//   1. Re-split the song into individual lines by scanning the grammar-note for
//      `**Line N: <jp>**` patterns (and any italic romaji that follows each header).
//   2. Re-bucket the vocabulary in `line[0].words` against each recovered line's `original`
//      by checking whether the line's text contains the word's `surface`. Particles and
//      pure-kana words can land anywhere they appear; words with distinctive kanji land on
//      the right line. Words that match no line stay on line 1 as a fallback.
//
// The check is conservative: recovery only fires when the breakdown has exactly one line
// AND that line's `grammarNote` mentions `**Line `. Correctly-parsed breakdowns from the
// fixed parser flow straight through unchanged.
enum SongBreakdownRecovery {

    // Returns a recovered copy of the breakdown, or the input untouched when nothing looked
    // broken or nothing could be extracted. Idempotent — running it twice yields the same
    // shape because the recovered line[0] no longer has a `**Line ` grammar note.
    static func recoverIfNeeded(_ breakdown: SongBreakdown) -> SongBreakdown {
        guard breakdown.lines.count == 1,
              let line0 = breakdown.lines.first,
              let grammar = line0.grammarNote,
              grammar.contains("**Line ")
        else {
            return breakdown
        }

        let extracted = extractTrailingLines(from: grammar)
        guard extracted.isEmpty == false else {
            return breakdown
        }

        let allOriginals = [line0.original] + extracted.map { $0.original }
        let regroupedWordsByOriginalIndex = regroup(words: line0.words, against: allOriginals)

        let rebuiltLine0 = SongLine(
            index: line0.index,
            original: line0.original,
            romaji: line0.romaji,
            words: regroupedWordsByOriginalIndex[0] ?? [],
            gist: line0.gist,
            grammarNote: nil,
            reference: line0.reference
        )

        var rebuilt: [SongLine] = [rebuiltLine0]
        for (i, line) in extracted.enumerated() {
            rebuilt.append(SongLine(
                index: line.index,
                original: line.original,
                romaji: line.romaji,
                words: regroupedWordsByOriginalIndex[i + 1] ?? [],
                gist: nil,
                grammarNote: nil,
                reference: nil
            ))
        }

        return SongBreakdown(
            noteID: breakdown.noteID,
            sourceTextHash: breakdown.sourceTextHash,
            generatedAt: breakdown.generatedAt,
            provider: breakdown.provider,
            lines: rebuilt,
            schemaVersion: breakdown.schemaVersion
        )
    }

    // Pulls every `**Line N: <jp>**` (optionally followed by `*<romaji>*`) from the input.
    // Non-greedy match on the Japanese segment so back-to-back headers don't merge. Uses
    // NSRegularExpression because Swift `Regex` literals would need Swift 5.7+ tooling
    // configured on this target and the existing parser is regex-free for the same reason.
    private static func extractTrailingLines(from text: String) -> [SongLine] {
        let pattern = #"\*\*Line\s+(\d+)\s*:\s*([^*]+?)\s*\*\*\s*(?:\*([^*][^*\n]*?)\*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var lines: [SongLine] = []
        regex.enumerateMatches(in: text, options: [], range: nsRange) { match, _, _ in
            guard let match = match else { return }
            guard let indexRange = Range(match.range(at: 1), in: text) else { return }
            guard let jpRange = Range(match.range(at: 2), in: text) else { return }
            guard let index = Int(text[indexRange]) else { return }
            let original = String(text[jpRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard original.isEmpty == false else { return }
            var romaji: String? = nil
            if let romajiRange = Range(match.range(at: 3), in: text) {
                let candidate = String(text[romajiRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.isEmpty == false { romaji = candidate }
            }
            lines.append(SongLine(
                index: index,
                original: original,
                romaji: romaji,
                words: [],
                gist: nil,
                grammarNote: nil,
                reference: nil
            ))
        }
        return lines
    }

    // Buckets a flat list of words into per-line arrays by checking which line's `original`
    // contains the word's `surface`. Order within each bucket is preserved. Words that match
    // no line fall back to line 0 so the user still sees them somewhere.
    private static func regroup(words: [SongWord], against originals: [String]) -> [Int: [SongWord]] {
        var bucket: [Int: [SongWord]] = [:]
        for word in words {
            let target = firstOriginalContaining(surface: word.surface, in: originals) ?? 0
            bucket[target, default: []].append(word)
        }
        return bucket
    }

    // Locates the first original line whose text contains the given surface verbatim, or
    // — when the verbatim surface doesn't match — a progressively shorter kanji-bearing
    // prefix of the surface. The prefix fallback handles dictionary-form vocabulary against
    // conjugated mentions in the original (e.g. surface "流れる" matching line text "流れて").
    // Trims any markdown/punctuation that the LLM occasionally left on the surface so
    // kanji-bearing bullets still match. Returns nil when no prefix matches anywhere.
    private static func firstOriginalContaining(surface raw: String, in originals: [String]) -> Int? {
        let surface = raw
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*~`'\"()「」『』"))
        guard surface.isEmpty == false else { return nil }
        // Try the full surface first, then trim one trailing char at a time. Stop when the
        // remaining prefix is too short to be specific (< 2 chars) or loses its kanji anchor
        // — a pure-kana 1-char prefix would match almost any line and cause misrouting.
        let chars = Array(surface)
        var end = chars.count
        while end >= 1 {
            let candidate = String(chars[0..<end])
            if end < chars.count {
                if candidate.count < 2 { break }
                if ScriptClassifier.containsKanji(candidate) == false { break }
            }
            for (i, original) in originals.enumerated() {
                if original.contains(candidate) { return i }
            }
            end -= 1
        }
        return nil
    }
}
