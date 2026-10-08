import Foundation

// Per-gap inputs for the boundary model: what the lattice and the path search say about each gap
// between two characters. The training data (segcli features, scripts/segmentation-eval) and the app
// compute them with this one type, so the model never sees features computed two different ways.
// Offsets are Characters, the unit the path search uses; gap i (1..<n) is the gap before character i.
nonisolated enum BoundaryFeatures {
    // Values per gap: dictionary edges ending there by length 1/2/3/4+, starting there by length
    // 1/2/3/4+, edges crossing it, the longest crossing edge's length, and the cheapest node cost
    // (centi-nats) of an edge ending and of one starting there, -1 when there is none.
    static let gapFeatureCount = 12

    // Coarse script of one character — the model's only view of a character besides its identity.
    // 0 kanji, 1 hiragana, 2 katakana, 3 prolonged sound mark, 4 latin letter, 5 digit,
    // 6 punctuation or space, 7 anything else.
    static func scriptClass(_ character: Character) -> Int {
        if character == "ー" { return 3 }
        guard let scalar = character.unicodeScalars.first else { return 7 }
        if ScriptClassifier.isKanjiScalar(scalar) || character == "々" { return 0 }
        if ScriptClassifier.isHiraganaScalar(scalar) { return 1 }
        if ScriptClassifier.isKatakanaScalar(scalar) || ScriptClassifier.isHalfWidthKatakanaScalar(scalar) { return 2 }
        if character.isLetter && character.isASCII || ("Ａ"..."Ｚ").contains(character) || ("ａ"..."ｚ").contains(character) { return 4 }
        if character.isNumber { return 5 }
        if character.isWhitespace || character.isPunctuation || character.isSymbol || ScriptClassifier.isJapanesePunctuation(character) { return 6 }
        return 7
    }

    // Where the chosen path cuts (1) and doesn't (0), per gap 1..<n — the shipped segmentation the
    // model is asked to agree or disagree with.
    static func pathCuts(_ path: [LatticeEdge], in text: String) -> [Int] {
        let offsets = characterOffsets(in: text)
        let n = text.count
        var cuts = [Int](repeating: 0, count: n + 1)
        for edge in path {
            guard let end = offsets[edge.end] else { continue }
            cuts[end] = 1
        }
        return Array(cuts[1..<max(1, n)])
    }

    // The lattice's evidence at each gap 1..<n, gapFeatureCount values each (see gapFeatureCount).
    static func gapFeatures(lattice: [LatticeEdge], in text: String) -> [[Int]] {
        let offsets = characterOffsets(in: text)
        let n = text.count
        var gaps = [[Int]](repeating: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, -1], count: n + 1)
        for edge in lattice where edge.isDictionaryMatch {
            guard let start = offsets[edge.start], let end = offsets[edge.end], end > start else { continue }
            let bucket = min(end - start, 4) - 1
            let cost = SegmenterScoring.edgeCost(edge)
            if end < n {
                gaps[end][bucket] += 1
                gaps[end][10] = gaps[end][10] < 0 ? cost : min(gaps[end][10], cost)
            }
            if start > 0 {
                gaps[start][4 + bucket] += 1
                gaps[start][11] = gaps[start][11] < 0 ? cost : min(gaps[start][11], cost)
            }
            // Every gap strictly inside the edge is one this word would join across.
            for i in (start + 1)..<end {
                gaps[i][8] += 1
                gaps[i][9] = max(gaps[i][9], end - start)
            }
        }
        return Array(gaps[1..<max(1, n)])
    }

    // Character offset of every index on a Character boundary of text, in one walk; String.distance
    // per edge would be O(n) each.
    static func characterOffsets(in text: String) -> [String.Index: Int] {
        var offsets: [String.Index: Int] = [:]
        offsets.reserveCapacity(text.count + 1)
        var index = text.startIndex
        var offset = 0
        offsets[index] = 0
        while index < text.endIndex {
            index = text.index(after: index)
            offset += 1
            offsets[index] = offset
        }
        return offsets
    }
}
