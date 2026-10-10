import Foundation

// Context for the readings `build` picked by frequency alone. Two passes over the finished ruby:
//   1. ReadingContextTable: each word with more than one dictionary reading takes the reading
//      Tatoeba's counts favour between the classes of the words either side (方 after a verb →
//      かた, 時 after a number → じ).
//   2. Where the counts kept the frequency reading, Apple's tokenizer (AppleTokenReadings) may still
//      swap in a suffix or counter reading of that spelling (SurfaceReadingData.suffixOrCounterReadings).
// held2k 91.09% → 95.12%, fresh5k 94.79% → 96.85% on scripts/segmentation-eval/score_readings.py.
// Readings the after-の rule set are left alone: that rule comes from JMdict's own expressions.
nonisolated extension FuriganaResolver {
    // Rewrites `furigana` in place; `fixedLocations` are ruby the after-の rule placed.
    func applyContextualReadings(
        to furigana: inout [Int: String],
        lengths: [Int: Int],
        edges: [LatticeEdge],
        sourceText: String,
        surfaceReadingData: SurfaceReadingDataMap,
        fixedLocations: Set<Int>
    ) {
        let nsText = sourceText as NSString
        var countsChanged = Set<Int>()
        if let table = ReadingContextTable.bundled, let transitionTable = (segmenter as? Segmenter)?.transitionTable {
            // A neighbour's class as the counts name it: text the dictionary doesn't cover and the
            // ends of the text are BOUNDARY.
            func className(_ edge: LatticeEdge?) -> String {
                guard let edge, edge.isDictionaryMatch else { return TransitionClass.boundary }
                return TransitionClass.name(surface: edge.surface, partOfSpeech: edge.partOfSpeech, lexical: transitionTable.lexical)
            }
            for (index, edge) in edges.enumerated() where edge.isDictionaryMatch {
                guard let run = singleRunRange(of: edge, in: sourceText),
                      fixedLocations.contains(run.location) == false,
                      lengths[run.location] == run.length,
                      let current = furigana[run.location] else { continue }
                let candidates = runReadingCandidates(for: edge.surface, surfaceReadingData: surfaceReadingData)
                guard candidates.count > 1,
                      let chosen = table.choose(
                        kanji: nsText.substring(with: run),
                        candidates: candidates,
                        previous: className(index > 0 ? edges[index - 1] : nil),
                        next: className(index + 1 < edges.count ? edges[index + 1] : nil)
                      ),
                      chosen != KanaNormalizer.katakanaToHiragana(current) else { continue }
                furigana[run.location] = chosen
                countsChanged.insert(run.location)
            }
        }

        let appleReadings = AppleTokenReadings.runReadings(in: sourceText)
        for (location, current) in furigana where countsChanged.contains(location) == false && fixedLocations.contains(location) == false {
            guard let length = lengths[location], let apple = appleReadings[location], apple.length == length,
                  apple.reading != KanaNormalizer.katakanaToHiragana(current) else { continue }
            let kanji = nsText.substring(with: NSRange(location: location, length: length))
            guard surfaceReadingData[kanji]?.suffixOrCounterReadings.contains(apple.reading) == true else { continue }
            furigana[location] = apple.reading
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
            for candidate in FuriganaResolver.candidateReadingsForSegment(lemma, surfaceReadingData: surfaceReadingData) {
                guard let run = inflectedStemReading(surface: surface, lemma: lemma, lemmaReading: candidate)
                    ?? firstKanjiRunReading(in: lemma, using: candidate) else { continue }
                let hiragana = KanaNormalizer.katakanaToHiragana(run)
                if readings.contains(hiragana) == false { readings.append(hiragana) }
            }
        }
        return readings
    }
}
