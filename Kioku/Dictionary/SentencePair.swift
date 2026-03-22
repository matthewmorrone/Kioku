import Foundation

// A Japanese–English sentence pair sourced from the Tatoeba corpus.
public struct SentencePair: Equatable {
    public let japanese: String
    public let english: String

    public init(japanese: String, english: String) {
        // Stores one bilingual sentence pair for example-sentence display.
        self.japanese = japanese
        self.english = english
    }
}
