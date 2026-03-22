import Foundation

// Pitch accent record for a word+kana pair, sourced from UniDic data.
public struct PitchAccent: Equatable {
    public let word: String
    public let kana: String
    // Part-of-speech kind annotation from UniDic, nil when not specified.
    public let kind: String?
    // Downstep position; 0 means flat (heiban) with no downstep.
    public let accent: Int
    // Total mora count of the kana form.
    public let morae: Int

    public init(word: String, kana: String, kind: String?, accent: Int, morae: Int) {
        // Stores one UniDic-derived pitch accent entry for a given word and reading pair.
        self.word = word
        self.kana = kana
        self.kind = kind
        self.accent = accent
        self.morae = morae
    }
}
