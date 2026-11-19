import Foundation

// What the reading model sees around a kanji run: the same 902 numbers scripts/calibration/reading_model.py
// trains on.
//   [0, 300)    the vector of the word directly before the run
//   [300, 600)  the vector of the word directly after it
//   600, 601    1 where the word before / after is BOUNDARY: past the text, or across text the dictionary
//               doesn't cover (those slots' vectors stay zero)
//   [602, 902)  the bag: the IDF-weighted sum of the vectors of the words within `window` places either
//               side (the run's own word excluded), scaled to unit length
// A word is its lemma, or its surface where the lemma is the word itself (ReadingNeighbour.lemma).
nonisolated struct ReadingContext: Sendable {
    // How many dictionary-matched words either side feed the bag.
    static let window = 5
    // Length of `features`.
    static let featureCount = 3 * WordVectorTable.dimensions + 2

    let features: [Float]

    // Builds the features. `previous` / `next` are the adjacent words, nil for BOUNDARY; `nearby` the words
    // within `window` places either side, nearest first on each side or in any order (the bag is a sum).
    init(previous: String?, next: String?, nearby: [String], vectors: WordVectorTable) {
        let dimensions = WordVectorTable.dimensions
        var features = [Float](repeating: 0, count: Self.featureCount)
        if let previous { vectors.add(previous, into: &features, at: 0) } else { features[2 * dimensions] = 1 }
        if let next { vectors.add(next, into: &features, at: dimensions) } else { features[2 * dimensions + 1] = 1 }
        var bag = [Float](repeating: 0, count: dimensions)
        for word in nearby {
            guard let weight = vectors.inverseDocumentFrequency(of: word) else { continue }
            vectors.add(word, scale: weight, into: &bag, at: 0)
        }
        let length = bag.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if length > 0 {
            for dimension in 0..<dimensions { features[2 * dimensions + 2 + dimension] = bag[dimension] / length }
        }
        self.features = features
    }

    // The dot product of `weights` (Self.featureCount of them) with the features: a reading's logit,
    // before its bias.
    func dot(_ weights: [Float]) -> Double {
        var sum: Float = 0
        for index in 0..<Self.featureCount { sum += weights[index] * features[index] }
        return Double(sum)
    }
}
