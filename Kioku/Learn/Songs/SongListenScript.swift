import Foundation

// Turns a SongBreakdown into a flat, ordered list of things to play/say: for each line, the
// sung audio clip (when a matched time range is available), then the Japanese original, then
// the English gist, then each word's Japanese surface followed by its English definition —
// before moving to the next line. This is the "script" that SongListenAudioService reads
// from; the language tag on each SongListenSegment is what drives the Japanese/English voice
// switching ("code switching") during synthesis, and the leading `.clip` step (when present)
// is what lets the listener hear the line sung before its breakdown explains it.
//
// Mirrors SongLineCard's `.sameAsLine` / `.parallelTo` fall-through: a chorus repeat line
// still speaks its own `original` text (it's literally different/identical lyrics being
// sung), but borrows the referenced line's gist/words when its own are empty, exactly like
// the card falls back for display.
//
// `nonisolated`: called from the `nonisolated` SongListenAudioService (see that file's header
// comment) — without this, the module's default MainActor isolation would make `build`
// callable only from the main actor.
nonisolated enum SongListenScript {
    // Builds the ordered step list for a full breakdown. Pure function of its inputs so a
    // given breakdown + line-range map always produces the same script (and therefore the
    // same audio). `lineRanges` mirrors the per-line play button's own range lookup
    // (SongLineCueMatcher.computeRanges) — pass an empty map (the default) to render
    // narration-only, e.g. when the note has no audio attachment.
    static func build(
        from breakdown: SongBreakdown,
        lineRanges: [Int: (startMs: Int, endMs: Int)] = [:]
    ) -> [SongListenStep] {
        var steps: [SongListenStep] = []
        let linesByIndex = Dictionary(uniqueKeysWithValues: breakdown.lines.map { ($0.index, $0) })

        for line in breakdown.lines {
            let original = line.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard original.isEmpty == false else { continue }

            if let range = lineRanges[line.index] {
                steps.append(.clip(lineIndex: line.index, startMs: range.startMs, endMs: range.endMs))
            }

            steps.append(.speech(SongListenSegment(lineIndex: line.index, kind: .sentence, text: original, language: .japanese)))

            if let gist = effectiveGist(for: line, linesByIndex: linesByIndex), gist.isEmpty == false {
                steps.append(.speech(SongListenSegment(lineIndex: line.index, kind: .translation, text: gist, language: .english)))
            }

            for word in effectiveWords(for: line, linesByIndex: linesByIndex) {
                let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                guard surface.isEmpty == false else { continue }
                steps.append(.speech(SongListenSegment(lineIndex: line.index, kind: .wordSurface, text: surface, language: .japanese)))

                let definition = SongLineCard.stripInlineMarkdown(word.definition)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if definition.isEmpty == false {
                    steps.append(.speech(SongListenSegment(lineIndex: line.index, kind: .wordDefinition, text: definition, language: .english)))
                }
            }
        }
        return steps
    }

    // Same "own value, else the referenced line's value" rule as SongLineCard.effectiveGist.
    private static func effectiveGist(for line: SongLine, linesByIndex: [Int: SongLine]) -> String? {
        if let g = line.gist, g.isEmpty == false { return g }
        if let reference = line.reference {
            return referencedLine(for: reference, linesByIndex: linesByIndex)?.gist
        }
        return nil
    }

    // Same fall-through as SongLineCard.effectiveWords.
    private static func effectiveWords(for line: SongLine, linesByIndex: [Int: SongLine]) -> [SongWord] {
        if line.words.isEmpty == false { return line.words }
        if let reference = line.reference {
            return referencedLine(for: reference, linesByIndex: linesByIndex)?.words ?? []
        }
        return []
    }

    // Resolves a `.sameAsLine` / `.parallelTo` reference to its target line, if present.
    private static func referencedLine(for reference: LineReference, linesByIndex: [Int: SongLine]) -> SongLine? {
        switch reference {
        case .sameAsLine(let n): return linesByIndex[n]
        case .parallelTo(line: let n, substitution: _): return linesByIndex[n]
        }
    }
}
