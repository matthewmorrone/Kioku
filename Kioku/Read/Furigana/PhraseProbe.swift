import Foundation

// The text around a kanji run as PhraseReadingEvidence looks a phrase up in it: up to `window` units
// either side, spaces between words left out, the run replaced by `middle` (the kanji itself, or one of
// its readings). Every probe position keeps the note offset it came from, so a phrase found in the
// probe can be held to the note's word boundaries.
nonisolated struct PhraseProbe {
    // The probe text.
    let text: String
    // Probe UTF-16 offsets of `middle`.
    private let middleStart: Int
    private let middleEnd: Int
    // Per probe UTF-16 unit, the note offset where it starts and where it ends; nil inside `middle`,
    // which has no note offsets of its own.
    private let starts: [Int?]
    private let ends: [Int?]

    // Builds the probe around `run` in `note`. `kanaOnlyBefore` stops the text before the run at the
    // first character that isn't kana. A line break ends the probe on either side.
    init(run: NSRange, in note: NSString, middle: String, kanaOnlyBefore: Bool) {
        var before: [(unit: unichar, offset: Int)] = []
        var location = run.location
        while location > 0, before.count < PhraseReadingEvidence.window {
            let range = note.rangeOfComposedCharacterSequence(at: location - 1)
            let character = note.substring(with: range)
            if Self.isSpace(character) { location = range.location; continue }
            if character.contains(where: \.isNewline) { break }
            if kanaOnlyBefore, ScriptClassifier.isPureHiragana(character) == false, ScriptClassifier.isPureKatakana(character) == false { break }
            before.insert(contentsOf: (0..<range.length).map { (note.character(at: range.location + $0), range.location + $0) }, at: 0)
            location = range.location
        }
        var after: [(unit: unichar, offset: Int)] = []
        location = run.location + run.length
        while location < note.length, after.count < PhraseReadingEvidence.window {
            let range = note.rangeOfComposedCharacterSequence(at: location)
            let character = note.substring(with: range)
            location = range.location + range.length
            if Self.isSpace(character) { continue }
            if character.contains(where: \.isNewline) { break }
            after.append(contentsOf: (0..<range.length).map { (note.character(at: range.location + $0), range.location + $0) })
        }
        let middleUnits = Array(middle.utf16)
        var units: [unichar] = before.map(\.unit)
        var starts: [Int?] = before.map(\.offset)
        var ends: [Int?] = before.map { $0.offset + 1 }
        for index in middleUnits.indices {
            units.append(middleUnits[index])
            starts.append(index == 0 ? run.location : nil)
            ends.append(index == middleUnits.count - 1 ? run.location + run.length : nil)
        }
        units += after.map(\.unit)
        starts += after.map(\.offset)
        ends += after.map { $0.offset + 1 }
        self.text = String(utf16CodeUnits: units, count: units.count)
        self.middleStart = before.count
        self.middleEnd = before.count + middleUnits.count
        self.starts = starts
        self.ends = ends
    }

    // The surfaces of the probe's dictionary words that cover `middle`, start and end on the note's word
    // boundaries, and take in one of the note's content words (`contentWordStarts`, by start offset)
    // besides the run's own word (`runWord`). A phrase of the kanji's word and function words alone says
    // nothing the words don't: JMdict's のほかに, そのうち (その家), このもと (この本) are spelled by
    // every の外に, その家, この本, and decided by them they broke 37 fresh5k readings.
    func coveringEdges(wordBoundaries: Set<Int>, contentWordStarts: Set<Int>, runWord: NSRange, segmenter: Segmenter) -> [String] {
        var surfaces: [String] = []
        for edge in segmenter.buildLattice(for: text) where edge.isDictionaryMatch {
            let start = edge.start.utf16Offset(in: text)
            let end = edge.end.utf16Offset(in: text)
            guard start <= middleStart, end >= middleEnd, start < middleStart || end > middleEnd,
                  let noteStart = noteOffset(start), let noteEnd = noteOffset(end),
                  wordBoundaries.contains(noteStart), wordBoundaries.contains(noteEnd),
                  contentWordStarts.contains(where: { $0 >= noteStart && $0 < noteEnd && $0 != runWord.location }) else { continue }
            surfaces.append(edge.surface)
        }
        return surfaces
    }

    // The note offset of the gap before probe unit `offset` (or after the last unit); nil inside `middle`.
    private func noteOffset(_ offset: Int) -> Int? {
        offset < starts.count ? starts[offset] : ends.last ?? nil
    }

    // True for a space between words (ASCII or full-width), which a phrase is read past.
    private static func isSpace(_ character: String) -> Bool {
        character.isEmpty == false && character.allSatisfy { $0.isWhitespace && $0.isNewline == false }
    }
}
