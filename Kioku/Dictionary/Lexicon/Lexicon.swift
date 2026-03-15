import Foundation

// Exposes UI-oriented lexical data methods by composing dictionary lookup, deinflection, and segmentation primitives.
public final class Lexicon {
    private let dictionaryStore: DictionaryStore?
    private let segmenter: Segmenter
    private let deinflector: Deinflector
    private let readingBySurface: [String: String]
    private let maxDepth = 4

    // Creates a lexical UI surface from already-initialized dictionary, deinflection, and segmentation dependencies.
    init(
        dictionaryStore: DictionaryStore?,
        segmenter: Segmenter,
        deinflector: Deinflector,
        readingBySurface: [String: String]
    ) {
        self.dictionaryStore = dictionaryStore
        self.segmenter = segmenter
        self.deinflector = deinflector
        self.readingBySurface = readingBySurface
    }

    // Returns kana reading for one surface while preserving already-kana input unchanged.
    public func reading(surface: String) -> String {
        if ScriptClassifier.isPureKana(surface) {
            return surface
        }

        let lookupReading = readingBySurface[surface]
        if let lookupReading {
            return lookupReading
        }

        let candidateLemmas = lemma(surface: surface)
        for candidateLemma in candidateLemmas {
            let lemmaReading = readingForLemma(candidateLemma)
            if let lemmaReading {
                if surface == candidateLemma {
                    return lemmaReading
                }

                let transitions = bestTransitions(for: surface, targetLemma: candidateLemma)
                if let transitions,
                   let inflectedReading = applySurfaceTransitions(to: lemmaReading, transitions: transitions) {
                    return inflectedReading
                }
            }
        }

        return surface
    }

    // Returns possible lemma candidates for one surface using grouped deinflection rules and dictionary admission.
    public func lemma(surface: String) -> [String] {
        let trimmedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSurface.isEmpty == false else {
            return []
        }

        let pathsByLemma = deinflector.deinflectionPaths(for: trimmedSurface)
        var admittedLemmas = pathsByLemma.keys.filter { candidate in
            segmenter.resolvesSurface(candidate)
        }

        if admittedLemmas.isEmpty && segmenter.resolvesSurface(trimmedSurface) {
            admittedLemmas = [trimmedSurface]
        }

        let preferredLemma = segmenter.preferredLemma(for: trimmedSurface)
        admittedLemmas.sort { lhs, rhs in
            if preferredLemma == lhs && preferredLemma != rhs {
                return true
            }

            if preferredLemma == rhs && preferredLemma != lhs {
                return false
            }

            let lhsDepth = shortestDepth(for: lhs, in: pathsByLemma)
            let rhsDepth = shortestDepth(for: rhs, in: pathsByLemma)
            if lhsDepth != rhsDepth {
                return lhsDepth < rhsDepth
            }

            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }

            return lhs < rhs
        }

        return admittedLemmas
    }

    // Returns normalized lookup candidates by combining each admitted lemma with its preferred reading.
    public func normalize(surface: String) -> [(lemma: String, reading: String)] {
        let lemmas = lemma(surface: surface)
        var normalizedCandidates: [(lemma: String, reading: String)] = []

        for candidateLemma in lemmas {
            if let lemmaReading = readingForLemma(candidateLemma) {
                normalizedCandidates.append((lemma: candidateLemma, reading: lemmaReading))
            }
        }

        return normalizedCandidates
    }

    // Returns best lemma plus grouped-rule chain that explains how the surface deinflects.
    public func inflectionInfo(surface: String) -> (lemma: String, chain: [String])? {
        let lemmas = lemma(surface: surface)
        guard let bestLemma = lemmas.first else {
            return nil
        }

        let chain = inflectionChain(surface: surface, targetLemma: bestLemma)
        return (lemma: bestLemma, chain: chain)
    }

    // Returns lexeme candidates matching one lemma and optional reading filter.
    public func lookupLexeme(_ lemma: String, _ reading: String? = nil) -> [DictionaryEntry] {
        let trimmedLemma = lemma.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLemma.isEmpty == false else {
            return []
        }

        let entries = lookupEntries(for: trimmedLemma)
        let trimmedReading = reading?.trimmingCharacters(in: .whitespacesAndNewlines)

        let matchingEntries = entries.filter { entry in
            let matchesLemma = entry.kanjiForms.contains(trimmedLemma) || entry.kanaForms.contains(trimmedLemma)
            guard matchesLemma else {
                return false
            }

            if let trimmedReading, trimmedReading.isEmpty == false {
                return entry.kanaForms.contains(trimmedReading)
            }

            return true
        }

        return matchingEntries
    }

    // Resolves one surface into ranked lexeme candidates.
    public func resolve(surface: String) -> [(lexeme: String, score: Double)] {
        let normalizedCandidates = normalize(surface: surface)
        var bestScoreByLexeme: [String: Double] = [:]

        for candidate in normalizedCandidates {
            let matchingLexemes = lookupLexeme(candidate.lemma, candidate.reading)
            let chain = inflectionChain(surface: surface, targetLemma: candidate.lemma)
            let baseScore = chain.isEmpty ? 1.0 : 0.98

            for entry in matchingLexemes {
                let lexemeName = entry.kanjiForms.first ?? entry.kanaForms.first ?? candidate.lemma
                if let existing = bestScoreByLexeme[lexemeName] {
                    bestScoreByLexeme[lexemeName] = max(existing, baseScore)
                } else {
                    bestScoreByLexeme[lexemeName] = baseScore
                }
            }
        }

        return bestScoreByLexeme
            .map { (lexeme: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }

                return lhs.lexeme < rhs.lexeme
            }
    }

    // Returns one core lexeme record by stable ID string.
    public func lexeme(_ id: String) -> DictionaryEntry? {
        guard let entryID = entryID(from: id) else {
            return nil
        }

        guard let dictionaryStore else {
            return nil
        }

        do {
            return try dictionaryStore.lookupEntry(entryID: entryID)
        } catch {
            print("lexeme lookup failed for id \(id): \(error)")
            return nil
        }
    }

    // Returns all displayable orthographic forms for one lexeme.
    public func forms(_ lexemeId: String) -> [(spelling: String, reading: String)] {
        guard let entry = lexeme(lexemeId) else {
            return []
        }

        let fallbackReading = entry.kanaForms.first ?? ""
        var builtForms: [(spelling: String, reading: String)] = []

        for kanjiForm in entry.kanjiForms {
            builtForms.append((spelling: kanjiForm, reading: fallbackReading))
        }

        for kanaForm in entry.kanaForms {
            builtForms.append((spelling: kanaForm, reading: kanaForm))
        }

        return uniqueForms(builtForms)
    }

    // Returns flattened gloss strings for one lexeme in persisted sense order.
    public func senses(_ lexemeId: String) -> [String] {
        guard let entry = lexeme(lexemeId) else {
            return []
        }

        var orderedGlosses: [String] = []
        for sense in entry.senses {
            for gloss in sense.glosses {
                let trimmedGloss = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedGloss.isEmpty == false {
                    orderedGlosses.append(trimmedGloss)
                }
            }
        }

        return orderedGlosses
    }

    // Returns primary reading for one lexeme using first kana form ordering.
    public func primaryReading(_ lexemeId: String) -> String? {
        guard let entry = lexeme(lexemeId) else {
            return nil
        }

        return entry.kanaForms.first
    }

    // Returns preferred headword display form for one lexeme.
    public func displayForm(_ lexemeId: String) -> (spelling: String, reading: String)? {
        let allForms = forms(lexemeId)
        guard allForms.isEmpty == false else {
            return nil
        }

        for form in allForms where ScriptClassifier.containsKanji(form.spelling) {
            return form
        }

        return allForms.first
    }

    // Returns the lexeme form that best matches one tapped surface.
    public func matchedForm(surface: String, lexemeId: String) -> (spelling: String, reading: String)? {
        let allForms = forms(lexemeId)
        if let exactMatch = allForms.first(where: { form in
            form.spelling == surface
        }) {
            return exactMatch
        }

        let lemmaCandidates = lemma(surface: surface)
        if let lemmaMatch = allForms.first(where: { form in
            lemmaCandidates.contains(form.spelling)
        }) {
            return lemmaMatch
        }

        return displayForm(lexemeId)
    }

    // Returns whether one text contains any kanji scalar.
    public func containsKanji(_ text: String) -> Bool {
        ScriptClassifier.containsKanji(text)
    }

    // Returns whether one text is entirely kana.
    public func isKana(_ text: String) -> Bool {
        ScriptClassifier.isPureKana(text)
    }

    // Returns unique kanji characters present in all lexeme forms.
    public func kanjiCharacters(_ lexemeId: String) -> [String] {
        let allForms = forms(lexemeId)
        var seenCharacters = Set<String>()
        var orderedCharacters: [String] = []

        for form in allForms {
            for character in form.spelling {
                let characterString = String(character)
                if ScriptClassifier.containsKanji(characterString),
                   seenCharacters.contains(characterString) == false {
                    seenCharacters.insert(characterString)
                    orderedCharacters.append(characterString)
                }
            }
        }

        return orderedCharacters
    }

    // Expands one lemma into inflected forms by inverting grouped deinflection rules and validating results.
    public func expandInflection(_ lemma: String) -> [String] {
        let trimmedLemma = lemma.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLemma.isEmpty == false else {
            return []
        }

        var visited = Set<String>([trimmedLemma])
        var queue: [(surface: String, depth: Int)] = [(surface: trimmedLemma, depth: 0)]
        var cursor = 0

        while cursor < queue.count {
            let item = queue[cursor]
            cursor += 1

            if item.depth >= maxDepth {
                continue
            }

            for labeledRule in deinflector.labeledRulesForExpansion() {
                let rule = labeledRule.rule
                guard item.surface.hasSuffix(rule.kanaOut) else {
                    continue
                }

                let stem = item.surface.dropLast(rule.kanaOut.count)
                let inflectedSurface = String(stem) + rule.kanaIn
                if visited.contains(inflectedSurface) {
                    continue
                }

                let inflectedLemmas = self.lemma(surface: inflectedSurface)
                if inflectedLemmas.contains(trimmedLemma) {
                    visited.insert(inflectedSurface)
                    queue.append((surface: inflectedSurface, depth: item.depth + 1))
                }
            }
        }

        return visited.sorted()
    }

    // Returns grouped-rule labels describing the preferred deinflection chain for one surface.
    public func inflectionChain(surface: String) -> [String] {
        let lemmas = lemma(surface: surface)
        guard let bestLemma = lemmas.first else {
            return []
        }

        return deinflector.inflectionChain(for: surface, targetLemma: bestLemma)
    }

    // Resolves dictionary entries for one surface using script-aware lookup mode selection.
    private func lookupEntries(for surface: String) -> [DictionaryEntry] {
        guard let dictionaryStore else {
            return []
        }

        do {
            let lookupMode: LookupMode = ScriptClassifier.containsKanji(surface) ? .kanjiAndKana : .kanaOnly
            return try dictionaryStore.lookup(surface: surface, mode: lookupMode)
        } catch {
            print("lookup entries failed for surface \(surface): \(error)")
            return []
        }
    }

    // Resolves preferred reading for one lemma from the in-memory reading map or dictionary fallback.
    private func readingForLemma(_ lemma: String) -> String? {
        if let mapReading = readingBySurface[lemma] {
            return mapReading
        }

        if ScriptClassifier.isPureKana(lemma) {
            return lemma
        }

        let entries = lookupLexeme(lemma, nil)
        for entry in entries {
            if let firstReading = entry.kanaForms.first {
                return firstReading
            }
        }

        return nil
    }

    // Applies inverse deinflection transitions in reverse order to project lemma reading back to surface reading.
    private func applySurfaceTransitions(
        to lemmaReading: String,
        transitions: [(label: String, kanaIn: String, kanaOut: String)]
    ) -> String? {
        var currentReading = lemmaReading

        for transition in transitions.reversed() {
            guard currentReading.hasSuffix(transition.kanaOut) else {
                return nil
            }

            let stem = currentReading.dropLast(transition.kanaOut.count)
            currentReading = String(stem) + transition.kanaIn
        }

        return currentReading
    }

    // Picks the shortest available deinflection depth for one candidate lemma.
    private func shortestDepth(
        for lemma: String,
        in pathsByLemma: [String: [(chain: [String], transitions: [(label: String, kanaIn: String, kanaOut: String)])]]
    ) -> Int {
        guard let paths = pathsByLemma[lemma], paths.isEmpty == false else {
            return Int.max
        }

        return paths.map { $0.chain.count }.min() ?? Int.max
    }

    // Picks transitions for one surface-to-lemma path so reading projection can preserve inflection morphology.
    private func bestTransitions(
        for surface: String,
        targetLemma: String
    ) -> [(label: String, kanaIn: String, kanaOut: String)]? {
        deinflector.bestTransitions(for: surface, targetLemma: targetLemma)
    }

    // Returns the preferred chain for one optional target lemma using shortest-path tie breaking.
    private func inflectionChain(surface: String, targetLemma: String?) -> [String] {
        let selectedLemma: String

        if let targetLemma {
            selectedLemma = targetLemma
        } else if let firstLemma = lemma(surface: surface).first {
            selectedLemma = firstLemma
        } else {
            return []
        }
        return deinflector.inflectionChain(for: surface, targetLemma: selectedLemma)
    }

    // Parses stable lexeme ID text to numeric dictionary entry ID.
    private func entryID(from id: String) -> Int64? {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawID = Int64(trimmedID) {
            return rawID
        }

        guard trimmedID.hasPrefix("lex_") else {
            return nil
        }

        let numericPart = String(trimmedID.dropFirst(4))
        return Int64(numericPart)
    }

    // Removes duplicate forms while preserving first-seen ordering semantics.
    private func uniqueForms(_ forms: [(spelling: String, reading: String)]) -> [(spelling: String, reading: String)] {
        var seen = Set<String>()
        var unique: [(spelling: String, reading: String)] = []

        for form in forms {
            let key = "\(form.spelling)|\(form.reading)"
            if seen.contains(key) {
                continue
            }

            seen.insert(key)
            unique.append(form)
        }

        return unique
    }
}
