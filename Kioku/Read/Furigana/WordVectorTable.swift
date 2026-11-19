import Foundation

// fastText's Japanese word vectors for the words the dictionary spells, as the dictionary build stored
// them (word_vectors, Resources/generate_db.py): unit vectors scaled by `quantisation` and rounded to
// Int8, each with the word's inverse document frequency. ReadingContext builds the reading model's
// features from them. Held flat in one array: 50,000 words × 300 bytes.
nonisolated final class WordVectorTable: Sendable {
    // Dimensions of a vector.
    static let dimensions = 300
    // The build stores a component as round(component × quantisation); dividing by it restores it.
    static let quantisation: Float = 200

    private let rowByWord: [String: Int]
    private let inverseDocumentFrequencies: [Float]
    private let components: [Int8]

    // Builds the table from its rows; a row whose vector is not `dimensions` bytes is skipped and logged.
    init(rows: [WordVectorRow]) {
        var rowByWord: [String: Int] = [:]
        var frequencies: [Float] = []
        var components: [Int8] = []
        components.reserveCapacity(rows.count * Self.dimensions)
        for row in rows {
            guard row.vector.count == Self.dimensions else {
                AppLog.error(.segmentation, "word_vectors: skipping \(row.word), \(row.vector.count) bytes")
                continue
            }
            rowByWord[row.word] = frequencies.count
            frequencies.append(Float(row.inverseDocumentFrequency))
            components.append(contentsOf: row.vector.map { Int8(bitPattern: $0) })
        }
        self.rowByWord = rowByWord
        self.inverseDocumentFrequencies = frequencies
        self.components = components
    }

    // The dictionary's table; nil when the dictionary has none or it can't be read, and furigana then
    // keeps the dictionary's frequency order.
    static func load(from store: DictionaryStore) -> WordVectorTable? {
        do {
            let rows = try store.fetchWordVectors()
            guard rows.isEmpty == false else {
                AppLog.error(.segmentation, "Dictionary has no word_vectors; furigana keeps the frequency order")
                return nil
            }
            return WordVectorTable(rows: rows)
        } catch {
            AppLog.error(.segmentation, "word_vectors failed to load: \(error)")
            return nil
        }
    }

    // Adds `scale × the word's vector` into `buffer` starting at `offset`, and says whether the word has
    // one. Words outside the vocabulary add nothing: the model never saw them either.
    @discardableResult
    func add(_ word: String, scale: Float = 1, into buffer: inout [Float], at offset: Int) -> Bool {
        guard let row = rowByWord[word] else { return false }
        let start = row * Self.dimensions
        let factor = scale / Self.quantisation
        for dimension in 0..<Self.dimensions {
            buffer[offset + dimension] += factor * Float(components[start + dimension])
        }
        return true
    }

    // The word's inverse document frequency in the counted sentences, the weight it carries in the
    // window's bag; nil for a word without a vector.
    func inverseDocumentFrequency(of word: String) -> Float? {
        rowByWord[word].map { inverseDocumentFrequencies[$0] }
    }
}
