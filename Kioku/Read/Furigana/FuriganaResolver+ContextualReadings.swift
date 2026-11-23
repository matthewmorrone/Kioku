import Foundation

// Context for the readings `build` picked by frequency alone. One rule for every word with more
// than one dictionary reading, from four sources in order of authority:
//   1. phrases: a reading that makes the words around it spell a dictionary expression holding
//      another content word decides (PhraseReadingEvidence: 態をみろ read ざま is ざまをみろ, 笑う門には福来たる
//      reads 門 かど), since the dictionary then names the reading outright;
//   2. usage: the reading model (ReadingContextTable), fitted on Tatoeba's readings and word vectors,
//      scores each reading from the words around the run (方 after a verb → かた, 時 after a number
//      → じ); a note that reads like web pages adds the web counts (ReadingRegisters);
//   3. Apple's tokenizer (AppleTokenReadings) adds a fixed vote to the reading it gives, which tips
//      close calls (後 → ご in 説明会後) but not clear ones (私 stays わたし);
//   4. the dictionary: its frequency order breaks ties, and decides alone when no other source has a say.
// held2k 91.09% → 95.03%, fresh5k 94.79% → 97.30% on scripts/segmentation-eval/score_readings.py.
nonisolated extension FuriganaResolver {
    // Rewrites `furigana` in place with the readings the sources agree on.
    func applyContextualReadings(
        to furigana: inout [Int: String],
        lengths: [Int: Int],
        edges: [LatticeEdge],
        sourceText: String,
        surfaceReadingData: SurfaceReadingDataMap
    ) {
        let choices = contextualReadingChoices(
            furigana: furigana, lengths: lengths, edges: edges, sourceText: sourceText, surfaceReadingData: surfaceReadingData
        )
        for choice in choices {
            if let chosen = choice.chosen, chosen != KanaNormalizer.katakanaToHiragana(choice.current) {
                furigana[choice.location] = chosen
            }
        }
    }

    // Every decision applyContextualReadings makes, with what it was made from: the kanji run, its
    // neighbours' classes, Apple's reading and each candidate's score. segcli's `readings` mode
    // prints these, so a wrong reading can be traced to the part that chose it.
    func contextualReadingChoices(
        furigana: [Int: String],
        lengths: [Int: Int],
        edges: [LatticeEdge],
        sourceText: String,
        surfaceReadingData: SurfaceReadingDataMap
    ) -> [ContextualReadingChoice] {
        let nsText = sourceText as NSString
        let table = (segmenter as? Segmenter)?.readingContexts
        let transitionTable = (segmenter as? Segmenter)?.transitionTable
        let appleReadings = AppleTokenReadings.runReadings(in: sourceText)
        // The note's register (everyday or web), told once for the whole text.
        let registers = (segmenter as? Segmenter)?.readingRegisters
        let register = registers?.classifier.register(of: sourceText)
        // The edge at `position` as the model names it (ReadingNeighbour): text the dictionary doesn't
        // cover and the ends of the text are BOUNDARY.
        func neighbour(at position: Int) -> ReadingNeighbour {
            guard edges.indices.contains(position), edges[position].isDictionaryMatch, let transitionTable else { return .boundary }
            let edge = edges[position]
            let name = TransitionClass.name(surface: edge.surface, partOfSpeech: edge.partOfSpeech, lexical: transitionTable.lexical)
            return ReadingNeighbour(surface: edge.surface, className: name, segmenter: segmenter)
        }
        // Every edge's neighbour once: each run's window reads up to ten of them.
        let neighbourByEdge = table == nil ? [] : edges.indices.map { neighbour(at: $0) }
        // The words of the dictionary-matched edges within the window either side of edge `index`, which
        // the model's bag sums; text the dictionary doesn't cover is skipped, as Tatoeba's gaps are.
        func nearbyWords(of index: Int) -> [String] {
            var words: [String] = []
            for direction in [-1, 1] {
                var position = index + direction
                var taken = 0
                while edges.indices.contains(position), taken < ReadingContext.window {
                    if let word = neighbourByEdge[position].word {
                        words.append(word)
                        taken += 1
                    }
                    position += direction
                }
            }
            return words
        }
        // Where the note's segments meet, in UTF-16 offsets: a phrase must start and end on one.
        // Where its content words start: a phrase must hold one besides the run's own word.
        var wordBoundaries: Set<Int> = [0, nsText.length]
        var contentWordStarts: Set<Int> = []
        for edge in edges {
            let range = NSRange(edge.start..<edge.end, in: sourceText)
            wordBoundaries.insert(range.location)
            wordBoundaries.insert(range.location + range.length)
            if edge.isDictionaryMatch, let lexical = transitionTable?.lexical,
               PhraseReadingEvidence.isContentWord(surface: edge.surface, partOfSpeech: edge.partOfSpeech, lexical: lexical) {
                contentWordStarts.insert(range.location)
            }
        }
        var choices: [ContextualReadingChoice] = []
        for (index, edge) in edges.enumerated() where edge.isDictionaryMatch {
            guard let run = singleRunRange(of: edge, in: sourceText),
                  lengths[run.location] == run.length,
                  let current = furigana[run.location] else { continue }
            let candidates = runReadingCandidates(for: edge.surface, surfaceReadingData: surfaceReadingData)
            guard candidates.count > 1 else { continue }
            // Apple's reading counts only when the dictionary lists it for this word.
            let apple = appleReadings[run.location].flatMap { $0.length == run.length && candidates.contains($0.reading) ? $0.reading : nil }
            let kanji = nsText.substring(with: run)
            let previousNeighbour = neighbourByEdge.indices.contains(index - 1) ? neighbourByEdge[index - 1] : .boundary
            let nextNeighbour = neighbourByEdge.indices.contains(index + 1) ? neighbourByEdge[index + 1] : .boundary
            let previous = previousNeighbour.className
            let next = nextNeighbour.className
            let phrase = (segmenter as? Segmenter).map {
                PhraseReadingEvidence.readings(
                    spellingPhrasesAround: run, in: nsText, candidates: candidates, wordBoundaries: wordBoundaries,
                    contentWordStarts: contentWordStarts, runWord: NSRange(edge.start..<edge.end, in: sourceText), segmenter: $0
                )
            } ?? []
            let scores = transitionTable == nil ? nil : table.flatMap { table in table.scores(
                kanji: kanji,
                candidates: candidates,
                context: ReadingContext(
                    previous: previousNeighbour.word, next: nextNeighbour.word,
                    nearby: nearbyWords(of: index), vectors: table.vectors
                ),
                appleReading: apple,
                phraseReadings: phrase,
                addedCounts: registers?.addedCounts(kanji: kanji, register: register) ?? [:]
            ) }
            let counted = scores.flatMap { ReadingContextTable.best(of: $0) }
            // The one reading that spells a phrase decides; several spelling one leave it to the counts.
            let phraseReading = phrase.count == 1 ? phrase.first : nil
            choices.append(ContextualReadingChoice(
                location: run.location, kanji: kanji, current: current, previous: previous, next: next,
                apple: apple, phrase: phrase, scores: scores ?? [], chosen: phraseReading ?? counted ?? apple
            ))
        }
        return choices
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

// One decision of FuriganaResolver.contextualReadingChoices: the kanji run at `location`, the reading
// `build` gave it (`current`), its neighbours' classes, Apple's reading, the readings that spell a
// phrase, every candidate's score, and the reading chosen (nil leaves `current`).
nonisolated struct ContextualReadingChoice {
    let location: Int
    let kanji: String
    let current: String
    let previous: String
    let next: String
    let apple: String?
    let phrase: Set<String>
    let scores: [ReadingScore]
    let chosen: String?
}
