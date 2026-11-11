import Foundation

// A Japanese–English sentence pair sourced from the Tatoeba corpus.
nonisolated public struct SentencePair: Equatable, Sendable {
    public let japanese: String
    public let english: String
    // How the word the sentence was found for is written in it (突きつけられた for 突きつける), when the
    // dictionary's token index says so; nil for a sentence found by scanning for a spelling.
    public let highlight: String?

    public init(japanese: String, english: String, highlight: String? = nil) {
        // Stores one bilingual sentence pair for example-sentence display.
        self.japanese = japanese
        self.english = english
        self.highlight = highlight
    }
}
