import Foundation

// Which readings of a kanji run turn the text around it into a dictionary expression, past the run's
// own word, that JMdict writes with this kanji read that way (PhraseReadingTable). Two ways to spell one:
//   - with the reading in place of the kanji: 態をみろ read ざま spells ざまをみろ ("serves you right"),
//     which JMdict lists only as ざまを見ろ, 様を見ろ and ざまをみろ; read たい it spells nothing;
//   - as written: 笑う門には福来たる is itself a JMdict spelling, whose 門 reads かど.
// Spaces between the words don't count (lyrics write 笑う門には　福来たる): the note's segments stay
// as they are, only the phrase is read past them. The furigana context pass weighs it beside the usage
// counts (FuriganaResolver+ContextualReadings): a phrase is the dictionary's own word for how a kanji
// reads in that company, where the counts only see the words either side.
nonisolated enum PhraseReadingEvidence {
    // How much text either side of the run a phrase may take in, in UTF-16 units, spaces not counted.
    // JMdict's expressions are mostly short (ざまをみろ, 気がする); a longer window only costs lattice work.
    static let window = 12

    // The candidates that spell a phrase around `run`. Kana only lining up with a phrase is not enough:
    // 保 read も before に spells にも, 指 read さし before で spells さしで, and neither phrase is written
    // with that kanji. The phrase must also be whole words: it starts and ends on `wordBoundaries`
    // (UTF-16 offsets where the note's segments meet), or 如何ですか would spell 如何で (いかんで) out
    // of half of です. It must hold a content word besides the run's own (`contentWordStarts`: start
    // offsets of the note's words that pass isContentWord; `runWord`: the run's own word). With the
    // reading in place, only kana before the run joins the phrase, since a kanji left beside a
    // substituted reading spells no JMdict form. Empty when no candidate does.
    static func readings(
        spellingPhrasesAround run: NSRange,
        in text: NSString,
        candidates: [String],
        wordBoundaries: Set<Int>,
        contentWordStarts: Set<Int>,
        runWord: NSRange,
        segmenter: Segmenter
    ) -> Set<String> {
        guard let table = segmenter.phraseReadings else { return [] }
        let kanji = text.substring(with: run)
        var spelled: Set<String> = []
        // As written: one probe, any candidate the matched phrase reads the kanji as.
        let written = PhraseProbe(run: run, in: text, middle: kanji, kanaOnlyBefore: false)
        for edge in written.coveringEdges(wordBoundaries: wordBoundaries, contentWordStarts: contentWordStarts, runWord: runWord, segmenter: segmenter) {
            for reading in candidates where table.phrase(edge, reads: kanji, as: reading) {
                spelled.insert(reading)
            }
        }
        // With each reading in place of the kanji.
        for reading in candidates where spelled.contains(reading) == false {
            let probe = PhraseProbe(run: run, in: text, middle: reading, kanaOnlyBefore: true)
            if probe.coveringEdges(wordBoundaries: wordBoundaries, contentWordStarts: contentWordStarts, runWord: runWord, segmenter: segmenter)
                .contains(where: { table.phrase($0, reads: kanji, as: reading) }) {
                spelled.insert(reading)
            }
        }
        return spelled
    }

    // True when a word can carry content of its own (a verb, noun, adjective or adverb), and is neither
    // one of the common function words the transition table classes by themselves (`lexical`: の, に,
    // この, その) nor a particle or the copula, which TransitionClass.tag puts first because such a
    // surface nearly always is one. The bits are a spelling's union over its entries, so "can": みろ is
    // also 見る's auxiliary sense and still counts, その is also 園 and is excluded as a function word.
    static func isContentWord(surface: String, partOfSpeech bits: UInt64, lexical: Set<String>) -> Bool {
        guard TransitionClass.name(surface: surface, partOfSpeech: bits, lexical: lexical).hasPrefix("w:") == false,
              PartOfSpeech.isParticle(bits) == false, PartOfSpeech.isCopula(bits) == false else { return false }
        let content = PartOfSpeechDetail.ichidanVerb | PartOfSpeechDetail.godanVerb | PartOfSpeechDetail.suruVerb
            | PartOfSpeechDetail.kuruVerb | PartOfSpeechDetail.otherVerb | PartOfSpeechDetail.iAdjective | PartOfSpeechDetail.naAdjective
        return bits & content != 0 || PartOfSpeech.isNoun(bits) || PartOfSpeech.isAdverb(bits)
    }
}
