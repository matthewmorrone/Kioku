import Foundation

// One dictionary word a tapped form could be: いった is 言う, 行く or 要る. `lemma` is the spelling the
// deinflection chain reached (いう), `headword` the entry's own written form (言う) and `reading` its
// kana. `surfaceReadings` are the entry's own kana forms carried through the same conjugation as the
// tapped form (怒る おこる on 怒り → おこり): the readings the sheet's arrows cycle while this word is
// shown. Built by Lexicon.lookupCandidates; the lookup sheet lists them when there is more than one.
nonisolated struct LookupCandidate: Equatable, Sendable {
    let lemma: String
    let headword: String
    let reading: String
    let entry: DictionaryEntry
    var surfaceReadings: [String] = []
}
