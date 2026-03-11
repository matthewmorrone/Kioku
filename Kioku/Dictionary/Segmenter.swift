import Foundation

// Builds segmentation lattice edges by querying dictionary prefix matches at each text position.
final class Segmenter {

    private let trie: DictionaryTrie
    private let deinflector: Deinflector?
    private let config: SegmenterConfig
    private let scoring: SegmenterScoring
    private let grammaticalizedCompoundVerbSuffixes = [
        "つづける", "続ける",
        "はじめる", "始める",
        "おわる", "終わる",
        "だす", "出す",
        "すぎる", "過ぎる",
        "なおす", "直す",
        "きる", "切る",
        "かける", "掛ける",
    ]
    private let boundaryCharacters: Set<Character> = [
        " ", "\t", "\n", "\r", "　",
        ".", ",", "!", "?", ";", ":",
        "。", "、", "！", "？", "・",
        "「", "」", "『", "』",
        "(", ")", "（", "）",
        "[", "]", "{", "}",
        "-", "—", "…", "，", "．"
    ]

    // Stores trie dependency used for prefix lookup when constructing lattices.
    init(
        trie: DictionaryTrie,
        deinflector: Deinflector? = nil,
        config: SegmenterConfig = SegmenterConfig(),
        scoring: SegmenterScoring = .default
    ) {
        self.trie = trie
        self.deinflector = deinflector
        self.config = config
        self.scoring = scoring
    }

    // Generates all dictionary-backed lattice edges for every start position in the input text.
    func buildLattice(for text: String) -> [LatticeEdge] {
        var edges: [LatticeEdge] = []

        var index = text.startIndex

        while index < text.endIndex {
            if boundaryCharacters.contains(text[index]) {
                let nextIndex = text.index(after: index)
                let boundarySurface = String(text[index..<nextIndex])
                edges.append(
                    LatticeEdge(
                        start: index,
                        end: nextIndex,
                        surface: boundarySurface,
                        lemma: boundarySurface
                    )
                )
                index = nextIndex
                continue
            }

            var keptMatches = 0

            var endIndex = index

            while endIndex < text.endIndex {
                let nextCharacter = text[endIndex]
                if isLineBreakCharacter(nextCharacter) {
                    break
                }

                endIndex = text.index(after: endIndex)
                let surfaceRange = index..<endIndex
                let characterLength = text.distance(from: surfaceRange.lowerBound, to: surfaceRange.upperBound)

                if characterLength > config.maxMatchLength {
                    break
                }

                let surface = String(text[surfaceRange])
                let lemmas = resolvedTrieLemmas(for: surface)

                for lemma in lemmas {
                    edges.append(
                        LatticeEdge(
                            start: surfaceRange.lowerBound,
                            end: surfaceRange.upperBound,
                            surface: surface,
                            lemma: lemma
                        )
                    )
                    keptMatches += 1
                }
            }

            // Ensures every character position has at least one outgoing edge.
            if keptMatches == 0 {
                let fallbackRange = unknownFallbackRange(in: text, startingAt: index)
                let fallbackSurface = String(text[fallbackRange])
                edges.append(
                    LatticeEdge(
                        start: fallbackRange.lowerBound,
                        end: fallbackRange.upperBound,
                        surface: fallbackSurface,
                        lemma: fallbackSurface
                    )
                )
            }

            index = text.index(after: index)
        }

        return edges
    }

    // Prints lattice edges with integer offsets and matched text for tokenizer debugging.
    func debugPrintLattice(for text: String) {
        var index = text.startIndex

        while index < text.endIndex {
            if boundaryCharacters.contains(text[index]) {
                let nextIndex = text.index(after: index)
                let boundarySurface = String(text[index..<nextIndex])
                let startOffset = text.distance(from: text.startIndex, to: index)
                let endOffset = text.distance(from: text.startIndex, to: nextIndex)
                print("\(startOffset)→\(endOffset) \(boundarySurface) [lemma: \(boundarySurface)]")
                index = nextIndex
                continue
            }

            var keptMatches = 0
            var endIndex = index

            while endIndex < text.endIndex {
                let nextCharacter = text[endIndex]
                if isLineBreakCharacter(nextCharacter) {
                    break
                }

                endIndex = text.index(after: endIndex)
                let surfaceRange = index..<endIndex
                let surface = String(text[surfaceRange])
                let characterLength = text.distance(from: surfaceRange.lowerBound, to: surfaceRange.upperBound)
                if characterLength > config.maxMatchLength {
                    break
                }

                let startOffset = text.distance(from: text.startIndex, to: surfaceRange.lowerBound)
                let endOffset = text.distance(from: text.startIndex, to: surfaceRange.upperBound)

                let matchedLemmas = resolvedTrieLemmas(for: surface).sorted()
                if matchedLemmas.isEmpty == false {
                    for lemma in matchedLemmas {
                        print("\(startOffset)→\(endOffset) \(escapedForDebug(surface)) [lemma: \(escapedForDebug(lemma))]")
                        keptMatches += 1

                        if keptMatches >= config.maxMatchesPerPosition {
                            break
                        }
                    }
                } else {
                    // print("\(startOffset)→\(endOffset) \(escapedForDebug(surface)) [no-match]")
                }

                if keptMatches >= config.maxMatchesPerPosition {
                    break
                }
            }

            if keptMatches == 0 {
                let nextIndex = text.index(after: index)
                let fallbackSurface = String(text[index..<nextIndex])
                let startOffset = text.distance(from: text.startIndex, to: index)
                let endOffset = text.distance(from: text.startIndex, to: nextIndex)
                print("\(startOffset)→\(endOffset) \(escapedForDebug(fallbackSurface)) [lemma: \(escapedForDebug(fallbackSurface))] [fallback]")
            }

            index = text.index(after: index)
        }
    }

    // Builds a greedy segmentation by selecting the farthest-reaching edge at each text index.
    func longestMatchSegments(for text: String) -> [Range<String.Index>] {
        longestMatchEdges(for: text).map { edge in
            edge.start..<edge.end
        }
    }

    // Produces both the full candidate lattice and the currently selected greedy path for one text snapshot.
    func longestMatchResult(for text: String) -> (latticeEdges: [LatticeEdge], selectedEdges: [LatticeEdge]) {
        let latticeEdges = buildLattice(for: text)
        var edgesByStart: [String.Index: [LatticeEdge]] = [:]

        for edge in latticeEdges {
            edgesByStart[edge.start, default: []].append(edge)
        }

        var selectedEdges: [LatticeEdge] = []
        var index = text.startIndex

        while index < text.endIndex {
            if let candidates = edgesByStart[index],
               let longestEdge = candidates.max(by: { lhs, rhs in
                   compareEdgePriority(lhs, rhs, in: text)
               }) {
                selectedEdges.append(longestEdge)
                index = longestEdge.end
            } else {
                let nextIndex = text.index(after: index)
                let fallbackSurface = String(text[index..<nextIndex])
                selectedEdges.append(
                    LatticeEdge(
                        start: index,
                        end: nextIndex,
                        surface: fallbackSurface,
                        lemma: fallbackSurface
                    )
                )
                index = nextIndex
            }
        }

        return (latticeEdges: latticeEdges, selectedEdges: selectedEdges)
    }

    // Builds a greedy segmentation edge list so downstream features can use chosen surface/lemma references.
    func longestMatchEdges(for text: String) -> [LatticeEdge] {
        longestMatchResult(for: text).selectedEdges
    }

    // Breaks longest-match ties by preferring higher-quality lemma resolution for the same span.
    private func compareEdgePriority(_ lhs: LatticeEdge, _ rhs: LatticeEdge, in text: String) -> Bool {
        let lhsLength = text.distance(from: lhs.start, to: lhs.end)
        let rhsLength = text.distance(from: rhs.start, to: rhs.end)
        if lhsLength != rhsLength {
            return lhsLength < rhsLength
        }

        let lhsLemmaScore = preferredLemmaScore(for: lhs.lemma, sourceSurface: lhs.surface)
        let rhsLemmaScore = preferredLemmaScore(for: rhs.lemma, sourceSurface: rhs.surface)
        if lhsLemmaScore != rhsLemmaScore {
            return lhsLemmaScore < rhsLemmaScore
        }

        if lhs.lemma.count != rhs.lemma.count {
            return lhs.lemma.count < rhs.lemma.count
        }

        return lhs.lemma > rhs.lemma
    }

    // Determines how far an unknown token should extend by grouping contiguous same-script runs.
    private func unknownFallbackRange(in text: String, startingAt index: String.Index) -> Range<String.Index> {
        let firstCharacter = text[index]
        guard let group = unknownGrouping(for: firstCharacter) else {
            let nextIndex = text.index(after: index)
            return index..<nextIndex
        }

        var currentIndex = text.index(after: index)
        var groupedLength = 1

        while currentIndex < text.endIndex && groupedLength < config.maxMatchLength {
            let character = text[currentIndex]
            if boundaryCharacters.contains(character) || isLineBreakCharacter(character) {
                break
            }

            if unknownGrouping(for: character) != group {
                break
            }

            currentIndex = text.index(after: currentIndex)
            groupedLength += 1
        }

        return index..<currentIndex
    }

    // Classifies unknown-token script groups used for simple fallback token coalescing.
    private func unknownGrouping(for character: Character) -> String? {
        guard let scalar = character.unicodeScalars.first else {
            return nil
        }

        let value = scalar.value
        if (0x3040...0x309F).contains(value) {
            return "hiragana"
        }

        if (0x30A0...0x30FF).contains(value) {
            return "katakana"
        }

        if (0x0030...0x0039).contains(value) || (0xFF10...0xFF19).contains(value) {
            return "number"
        }

        if (0x0041...0x005A).contains(value) ||
           (0x0061...0x007A).contains(value) ||
           (0xFF21...0xFF3A).contains(value) ||
           (0xFF41...0xFF5A).contains(value) {
            return "latin"
        }

        return nil
    }

    // Applies unknown penalty to non-dictionary non-boundary edges so punctuation separators are not over-penalized.
    private func shouldApplyUnknownTokenPenalty(_ edge: LatticeEdge) -> Bool {
        if isDictionaryEdge(edge) {
            return false
        }

        for character in edge.surface {
            if !boundaryCharacters.contains(character) {
                return true
            }
        }

        return false
    }

    // Determines whether an edge is dictionary-backed without database access.
    private func isDictionaryEdge(_ edge: LatticeEdge) -> Bool {
        resolvesSurface(edge.surface) || resolvesSurface(edge.lemma)
    }

    // Checks whether a surface string exists directly in the dictionary trie without deinflection.
    func containsSurface(_ surface: String) -> Bool {
        matchedTrieLemmas(for: surface).isEmpty == false
    }

    // Checks whether a surface resolves through the same trie plus deinflection path used by segmentation.
    func resolvesSurface(_ surface: String) -> Bool {
        resolvedTrieLemmas(for: surface).isEmpty == false
    }

    // Picks the highest-priority resolved lemma for a surface, preferring script-preserving kanji matches.
    func preferredLemma(for surface: String) -> String? {
        let lemmas = resolvedTrieLemmas(for: surface)
        guard lemmas.isEmpty == false else {
            return nil
        }

        return lemmas.max { lhs, rhs in
            let lhsScore = preferredLemmaScore(for: lhs, sourceSurface: surface)
            let rhsScore = preferredLemmaScore(for: rhs, sourceSurface: surface)

            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }

            if lhs.count != rhs.count {
                return lhs.count < rhs.count
            }

            return lhs > rhs
        }
    }

    // Resolves all trie-backed lemmas reachable from a surface, including deinflection candidates.
    private func resolvedTrieLemmas(for surface: String) -> Set<String> {
        var lemmas = matchedTrieLemmas(for: surface)

        if let deinflector {
            let candidates = deinflector.generateCandidates(for: surface)
            for candidate in candidates {
                lemmas.formUnion(matchedTrieLemmas(for: candidate))
            }
        }

        return lemmas
    }

    // Resolves all trie-backed membership lemmas for a surface, including katakana-to-hiragana fallback.
    private func matchedTrieLemmas(for surface: String) -> Set<String> {
        var lemmas: Set<String> = []

        if trie.contains(surface) {
            lemmas.insert(surface)
        }

        let hiraganaSurface = katakanaToHiragana(surface)
        if hiraganaSurface != surface, trie.contains(hiraganaSurface) {
            lemmas.insert(hiraganaSurface)
        }

        lemmas.formUnion(mixedScriptStemLemmas(for: surface))
        lemmas.formUnion(grammaticalizedCompoundVerbLemmas(for: surface))

        return lemmas
    }

    // Resolves grammaticalized compound verbs like 追いつづける to their first-verb lemmas for segmentation bias.
    private func grammaticalizedCompoundVerbLemmas(for surface: String) -> Set<String> {
        var lemmas: Set<String> = []

        for suffix in grammaticalizedCompoundVerbSuffixes {
            guard surface.count > suffix.count, surface.hasSuffix(suffix) else {
                continue
            }

            let stemEndIndex = surface.index(surface.endIndex, offsetBy: -suffix.count)
            let headStem = String(surface[..<stemEndIndex])
            if headStem.isEmpty {
                continue
            }

            lemmas.formUnion(verbStemLemmas(for: headStem))
        }

        return lemmas
    }

    // Resolves a continuative verb stem back to plausible dictionary lemmas.
    private func verbStemLemmas(for surface: String) -> Set<String> {
        var lemmas = mixedScriptStemLemmas(for: surface)

        if let trailingCharacter = surface.last,
           let dictionaryEnding = continuativeDictionaryEnding(for: trailingCharacter) {
            let dictionaryCandidate = String(surface.dropLast()) + String(dictionaryEnding)
            if trie.contains(dictionaryCandidate) {
                lemmas.insert(dictionaryCandidate)
            }
        }

        if surface.isEmpty == false {
            let ichidanCandidate = surface + "る"
            if trie.contains(ichidanCandidate) {
                lemmas.insert(ichidanCandidate)
            }
        }

        if surface == "し", trie.contains("する") {
            lemmas.insert("する")
        }

        if surface == "き" || surface == "来" {
            if trie.contains("くる") {
                lemmas.insert("くる")
            }
            if trie.contains("来る") {
                lemmas.insert("来る")
            }
        }

        return lemmas
    }

    // Resolves mixed-script continuative verb stems like 追い back to dictionary lemmas such as 追う.
    private func mixedScriptStemLemmas(for surface: String) -> Set<String> {
        guard ScriptClassifier.containsKanji(surface) else {
            return []
        }

        let characters = Array(surface)
        guard
            let trailingCharacter = characters.last,
            trailingCharacter.unicodeScalars.allSatisfy({ scalar in
                (0x3040...0x309F).contains(scalar.value)
            }),
            characters.dropLast().contains(where: { character in
                ScriptClassifier.containsKanji(String(character))
            })
        else {
            return []
        }

        guard let dictionaryEnding = continuativeDictionaryEnding(for: trailingCharacter) else {
            return []
        }

        let dictionaryCandidate = String(characters.dropLast()) + String(dictionaryEnding)
        guard trie.contains(dictionaryCandidate) else {
            return []
        }

        return [dictionaryCandidate]
    }

    // Maps godan continuative endings back to their dictionary-form okurigana.
    private func continuativeDictionaryEnding(for character: Character) -> Character? {
        switch character {
        case "い":
            return "う"
        case "き":
            return "く"
        case "ぎ":
            return "ぐ"
        case "し":
            return "す"
        case "ち":
            return "つ"
        case "に":
            return "ぬ"
        case "び":
            return "ぶ"
        case "み":
            return "む"
        case "り":
            return "る"
        default:
            return nil
        }
    }

    // Scores competing lemmas so furigana and segmentation can favor script-preserving dictionary forms.
    private func preferredLemmaScore(for lemma: String, sourceSurface: String) -> Int {
        var score = 0

        if lemma == sourceSurface {
            score += 100
        }

        if ScriptClassifier.containsKanji(sourceSurface) {
            if ScriptClassifier.containsKanji(lemma) {
                score += 40
            } else if ScriptClassifier.isPureKana(lemma) {
                score -= 20
            }
        }

        if ScriptClassifier.isPureKana(sourceSurface) && ScriptClassifier.isPureKana(lemma) {
            score += 10
        }

        return score
    }

    // Converts katakana scalars to hiragana so dictionary membership can fall back across kana scripts.
    private func katakanaToHiragana(_ text: String) -> String {
        let convertedScalars = text.unicodeScalars.map { scalar -> UnicodeScalar in
            switch scalar.value {
            case 0x30A1...0x30F6, 0x30FD...0x30FE:
                return UnicodeScalar(scalar.value - 0x60) ?? scalar
            default:
                return scalar
            }
        }

        return String(String.UnicodeScalarView(convertedScalars))
    }

    // Prints greedy longest-match segments line-by-line for tokenizer debugging.
    func debugPrintSegments(for text: String) {
        let segments = longestMatchSegments(for: text)

        for segment in segments {
            print(String(text[segment]))
        }
    }

    // Detects Unicode newline characters so scanned spans never cross line boundaries.
    private func isLineBreakCharacter(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                return true
            }
        }

        return false
    }

    // Escapes control line-break characters for stable single-line debug output.
    private func escapedForDebug(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

}
