import Foundation

// Context for the readings `build` picked by frequency alone. One rule for every word with more
// than one dictionary reading, from three sources in order of authority:
//   1. usage: Tatoeba's reading counts (ReadingContextTable) score each reading between the
//      classes of the words either side (方 after a verb → かた, 時 after a number → じ); a note that
//      reads like web pages adds the web counts (ReadingRegisters);
//   2. Apple's tokenizer (AppleTokenReadings) adds a fixed vote to the reading it gives, which tips
//      close calls (後 → ご in 説明会後) but not clear ones (私 stays わたし);
//   3. the dictionary: its frequency order breaks ties, and decides alone when neither has a say.
// A kanji the counts never saw takes Apple's reading when the dictionary lists it.
// held2k 91.09% → 95.19%, fresh5k 94.79% → 97.25% on scripts/segmentation-eval/score_readings.py.
nonisolated extension FuriganaResolver {
    // Rewrites `furigana` in place with the readings the three sources agree on.
    func applyContextualReadings(
        to furigana: inout [Int: String],
        lengths: [Int: Int],
        edges: [LatticeEdge],
        sourceText: String,
        surfaceReadingData: SurfaceReadingDataMap
    ) {
        let nsText = sourceText as NSString
        let table = ReadingContextTable.bundled
        let transitionTable = (segmenter as? Segmenter)?.transitionTable
        let appleReadings = AppleTokenReadings.runReadings(in: sourceText)
        // The note's register (everyday or web), told once for the whole text.
        let registers = (segmenter as? Segmenter)?.readingRegisters
        let register = registers?.classifier.register(of: sourceText)
        // A neighbour's class as the counts name it: text the dictionary doesn't cover and the
        // ends of the text are BOUNDARY.
        func className(_ edge: LatticeEdge?) -> String {
            guard let edge, edge.isDictionaryMatch, let transitionTable else { return TransitionClass.boundary }
            return TransitionClass.name(surface: edge.surface, partOfSpeech: edge.partOfSpeech, lexical: transitionTable.lexical)
        }
        for (index, edge) in edges.enumerated() where edge.isDictionaryMatch {
            guard let run = singleRunRange(of: edge, in: sourceText),
                  lengths[run.location] == run.length,
                  let current = furigana[run.location] else { continue }
            let candidates = runReadingCandidates(for: edge.surface, surfaceReadingData: surfaceReadingData)
            guard candidates.count > 1 else { continue }
            // Apple's reading counts only when the dictionary lists it for this word.
            let apple = appleReadings[run.location].flatMap { $0.length == run.length && candidates.contains($0.reading) ? $0.reading : nil }
            let kanji = nsText.substring(with: run)
            let counted = transitionTable == nil ? nil : table?.choose(
                kanji: kanji,
                candidates: candidates,
                previous: className(index > 0 ? edges[index - 1] : nil),
                next: className(index + 1 < edges.count ? edges[index + 1] : nil),
                appleReading: apple,
                addedCounts: registers?.addedCounts(kanji: kanji, register: register) ?? [:]
            )
            if let chosen = counted ?? apple, chosen != KanaNormalizer.katakanaToHiragana(current) {
                furigana[run.location] = chosen
            }
        }
    }

    // The UTF-16 range of an edge's one kanji run, or nil when it has none or several.
    private func singleRunRange(of edge: LatticeEdge, in sourceText: String) -> NSRange? {
        let runs = FuriganaAttributedString.kanjiRuns(in: edge.surface)
        guard runs.count == 1 else { return nil }
        let characters = Array(edge.surface)
        let segmentStart = NSRange(edge.start..<edge.end, in: sourceText).location
        let offset = String(characters[..<runs[0].start]).utf16.count
        let length = String(characters[runs[0].start..<runs[0].end]).utf16.count
        return NSRange(location: segmentStart + offset, length: length)
    }

    // The distinct hiragana readings the kanji run of `surface` can take: every reading of every word
    // the surface can be (lemmaCandidates), cropped to the run as furiganaAnnotations crops it. The
    // preferred lemma's readings come first, in the frequency order `build` uses. All lemmas, not just
    // the preferred one, because the preferred one is sometimes the wrong word and then the right
    // reading is never on offer: 入り read as the noun いり where it is 入る はいる, 甘く as the
    // adverb うまく where it is 甘い あまい.
    private func runReadingCandidates(for surface: String, surfaceReadingData: SurfaceReadingDataMap) -> [String] {
        let preferred = segmenter.preferredLemma(for: surface) ?? surface
        var lemmas = [preferred]
        for lemma in segmenter.lemmaCandidates(for: surface) where lemmas.contains(lemma) == false {
            lemmas.append(lemma)
        }
        var readings: [String] = []
        for lemma in lemmas {
            // A reading mixing katakana and hiragana (来る's クる) is a search spelling JMdict lists,
            // not a reading; offered, it put 来 → く on 来て.
            for candidate in FuriganaResolver.candidateReadingsForSegment(lemma, surfaceReadingData: surfaceReadingData)
            where ScriptClassifier.isPureKatakana(candidate) || ScriptClassifier.isPureHiragana(candidate) {
                guard let run = inflectedStemReading(surface: surface, lemma: lemma, lemmaReading: candidate)
                    ?? firstKanjiRunReading(in: lemma, using: candidate) else { continue }
                let hiragana = KanaNormalizer.katakanaToHiragana(run)
                if readings.contains(hiragana) == false { readings.append(hiragana) }
            }
        }
        return readings
    }
}
