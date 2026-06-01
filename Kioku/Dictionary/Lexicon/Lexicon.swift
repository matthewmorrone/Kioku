import Foundation

// Exposes UI-oriented lexical data methods by composing dictionary lookup, deinflection, and segmentation primitives.
nonisolated public final class Lexicon {
    let dictionaryStore: DictionaryStore?
    private let segmenter: any TextSegmenting
    let deinflector: Deinflector
    private let surfaceReadingData: [String: SurfaceReadingData]
    private let maxDepth = 4

    // Creates a lexical UI surface from already-initialized dictionary, deinflection, and segmentation dependencies.
    init(
        dictionaryStore: DictionaryStore?,
        segmenter: any TextSegmenting,
        deinflector: Deinflector,
        surfaceReadingData: [String: SurfaceReadingData]
    ) {
        self.dictionaryStore = dictionaryStore
        self.segmenter = segmenter
        self.deinflector = deinflector
        self.surfaceReadingData = surfaceReadingData
    }

    // Returns kana reading for one surface while preserving already-kana input unchanged.
    public func reading(surface: String) -> String {
        if ScriptClassifier.isPureKana(surface) {
            return surface
        }

        if let surfaceReading = readings(surface: surface).first {
            return surfaceReading
        }

        // Compute paths once so bestTransitions does not re-traverse below.
        let (candidateLemmas, pathsByLemma) = admittedLemmasAndPaths(for: surface)
        for entry in candidateLemmas {
            let candidateLemma = entry.lemma
            guard let lemmaReading = readingForLemma(candidateLemma) else {
                continue
            }

            if surface == candidateLemma {
                return lemmaReading
            }

            let transitions = deinflector.bestTransitions(from: pathsByLemma, targetLemma: candidateLemma)
            if let transitions,
               let inflectedReading = applySurfaceTransitions(to: lemmaReading, transitions: transitions) {
                return inflectedReading
            }
        }

        return surface
    }

    // Returns all valid readings for one surface, ordered by direct surface matches first and
    // then by deinflected lemma readings projected back onto the encountered surface.
    public func readings(surface: String) -> [String] {
        let trimmedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSurface.isEmpty == false else {
            return []
        }

        var readingCandidates: [String] = []
        var seenReadings = Set<String>()

        // Deduplicates candidate readings while preserving insertion order.
        func appendReading(_ reading: String?) {
            guard let reading, reading.isEmpty == false, seenReadings.contains(reading) == false else {
                return
            }

            seenReadings.insert(reading)
            readingCandidates.append(reading)
        }

        if ScriptClassifier.isPureKana(trimmedSurface) {
            appendReading(trimmedSurface)
            return readingCandidates
        }

        if let directSurfaceData = surfaceReadingData[trimmedSurface] {
            for reading in directSurfaceData.readings {
                appendReading(reading)
            }
        }

        let (candidateLemmas, pathsByLemma) = admittedLemmasAndPaths(for: trimmedSurface)
        for entry in candidateLemmas {
            let candidateLemma = entry.lemma
            let lemmaReadings = readingsForLemma(candidateLemma)
            guard lemmaReadings.isEmpty == false else {
                continue
            }

            if trimmedSurface == candidateLemma {
                for lemmaReading in lemmaReadings {
                    appendReading(lemmaReading)
                }
                continue
            }

            guard let transitions = deinflector.bestTransitions(from: pathsByLemma, targetLemma: candidateLemma) else {
                continue
            }

            for lemmaReading in lemmaReadings {
                appendReading(applySurfaceTransitions(to: lemmaReading, transitions: transitions))
            }
        }

        return readingCandidates
    }

    // Returns the most deeply deinflected admitted candidates for one surface.
    // Filters to max chain-depth only so intermediate forms (e.g. 話している from 話していた) are excluded.
    // Depth is chain.count from the deinflection paths — no separate computation needed.
    public func lemma(surface: String) -> [String] {
        let (entries, _) = admittedLemmasAndPaths(for: surface)
        guard entries.isEmpty == false else { return [] }

        let maxDepth = entries.map { $0.depth }.max() ?? 0
        guard maxDepth > 0 else { return entries.map { $0.lemma } }

        return entries.filter { $0.depth == maxDepth }.map { $0.lemma }
    }

    // Returns every admitted deinflection candidate for one surface, including intermediate
    // forms that lemma(surface:) filters out. Use when a caller wants to expose all
    // linguistically reachable lemmas to the UI (e.g. cycling readings via the lookup arrows
    // for 触れられない, which is reached via both 触れる at depth 2 and 触る at depth 3 — both
    // should be available even though lemma() returns only the deepest).
    // Ordering preserves admittedLemmasAndPaths' picker sort (preferred lemma, then descending depth).
    public func allAdmittedLemmas(surface: String) -> [String] {
        let (entries, _) = admittedLemmasAndPaths(for: surface)
        return entries.map { $0.lemma }
    }

    // Returns each admitted lemma paired with its inflection chain and the lemma's readings
    // projected forward through the chain back onto the original surface. This is what the
    // lookup sheet's reading-arrow cycle needs: for the surface 触れられない, the deinflector
    // admits both 触る (depth 3, reading さわる) and 触れる (depth 2, reading ふれる). The bare
    // lemma readings don't align with the inflected surface (the okurigana れられない is longer
    // than ふれる itself), so the header renderer can't crop them to per-kanji ruby. Projecting
    // each lemma reading forward via applySurfaceTransitions yields さわれられない and
    // ふれられない — both of which DO align with the surface and crop cleanly to さわ / ふ over
    // the kanji 触. Surfaces whose lemmas don't project (because no transitions are found) are
    // omitted from the result. Ordering follows allAdmittedLemmas.
    public func surfaceReadingsByLemma(surface: String) -> [(lemma: String, chain: [String], surfaceReadings: [String])] {
        let trimmedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSurface.isEmpty == false else { return [] }

        let (entries, pathsByLemma) = admittedLemmasAndPaths(for: trimmedSurface)
        var result: [(lemma: String, chain: [String], surfaceReadings: [String])] = []
        for entry in entries {
            let lemmaReadings = readingsForLemma(entry.lemma)
            guard lemmaReadings.isEmpty == false else { continue }
            let chain = deinflector.inflectionChain(from: pathsByLemma, targetLemma: entry.lemma)
            var projected: [String] = []
            var seen: Set<String> = []
            if trimmedSurface == entry.lemma {
                // Surface IS its own lemma — lemma readings ARE surface readings, no projection needed.
                for reading in lemmaReadings where seen.insert(reading).inserted {
                    projected.append(reading)
                }
            } else if let transitions = deinflector.bestTransitions(from: pathsByLemma, targetLemma: entry.lemma) {
                for lemmaReading in lemmaReadings {
                    guard let surfaceReading = applySurfaceTransitions(to: lemmaReading, transitions: transitions),
                          seen.insert(surfaceReading).inserted else { continue }
                    projected.append(surfaceReading)
                }
            }
            guard projected.isEmpty == false else { continue }
            result.append((lemma: entry.lemma, chain: chain, surfaceReadings: projected))
        }
        return result
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
        // Compute paths once; extract the chain from them rather than re-traversing via deinflector.inflectionChain.
        let (entries, pathsByLemma) = admittedLemmasAndPaths(for: surface)

        // admittedLemmasAndPaths deliberately keeps deinflection candidates that have NO JMdict
        // entry (see its POS-gate comment) so other call sites can fall back to surface display.
        // This method's result, though, is rendered verbatim as the header's dictionary-form
        // subtitle, so it must only ever name a real dictionary word. Without this guard a surface
        // like どこかに — which the deinflector mechanically rewrites to どこかぬ via the near-extinct
        // ぬ-verb 連用形 rule (に→ぬ) — would display どこかぬ, a non-word, as its lemma. Pick the
        // best-ranked entry the dictionary actually knows; if none resolve, the surface isn't a
        // recognized inflection and we report none (callers nil-coalesce to the surface). This
        // mirrors the implicit guard readings() already has via empty lemma readings.
        guard let best = entries.first(where: { lookupEntries(for: $0.lemma).isEmpty == false }) else {
            return nil
        }

        let chain = deinflector.inflectionChain(from: pathsByLemma, targetLemma: best.lemma)
        return (lemma: best.lemma, chain: chain)
    }

    // Returns the kanaIn→kanaOut transition steps for the best deinflection path to the top lemma.
    public func inflectionTransitions(surface: String) -> [(label: String, kanaIn: String, kanaOut: String)]? {
        let (entries, pathsByLemma) = admittedLemmasAndPaths(for: surface)
        guard let best = entries.first else {
            return nil
        }
        return deinflector.bestTransitions(from: pathsByLemma, targetLemma: best.lemma)
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
            let matchesLemma = entry.kanjiForms.contains(where: { $0.text == trimmedLemma })
                || entry.kanaForms.contains(where: { $0.text == trimmedLemma })
            guard matchesLemma else {
                return false
            }

            if let trimmedReading, trimmedReading.isEmpty == false {
                return entry.kanaForms.contains(where: { $0.text == trimmedReading })
            }

            return true
        }

        return matchingEntries
    }

    // Resolves one surface into ranked lexeme candidates using a single deinflection traversal.
    // Previously called normalize() then inflectionChain() per candidate, each triggering separate traversals.
    public func resolve(surface: String) -> [(lexeme: String, score: Double)] {
        let (admittedEntries, pathsByLemma) = admittedLemmasAndPaths(for: surface)
        var bestScoreByLexeme: [String: Double] = [:]

        for admittedEntry in admittedEntries {
            let candidateLemma = admittedEntry.lemma
            guard let lemmaReading = readingForLemma(candidateLemma) else {
                continue
            }

            let matchingLexemes = lookupLexeme(candidateLemma, lemmaReading)
            let chain = deinflector.inflectionChain(from: pathsByLemma, targetLemma: candidateLemma)
            let baseScore = chain.isEmpty ? 1.0 : 0.98

            for entry in matchingLexemes {
                let lexemeName = entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? candidateLemma
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

    // Expands one lemma into inflected forms by inverting grouped deinflection rules and validating results.
    // Uses deinflectionPaths directly instead of lemma(surface:) to skip the segmenter admission checks —
    // the target lemma is already known valid, so we only need to confirm the reverse path exists.
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

                let paths = deinflector.deinflectionPaths(for: inflectedSurface)
                if paths[trimmedLemma] != nil {
                    visited.insert(inflectedSurface)
                    queue.append((surface: inflectedSurface, depth: item.depth + 1))
                }
            }
        }

        return visited.sorted()
    }

    // Returns grouped-rule labels describing the preferred deinflection chain for one surface.
    public func inflectionChain(surface: String) -> [String] {
        // Compute paths once; extract chain without a second traversal inside deinflector.inflectionChain.
        let (entries, pathsByLemma) = admittedLemmasAndPaths(for: surface)
        guard let best = entries.first else {
            return []
        }

        return deinflector.inflectionChain(from: pathsByLemma, targetLemma: best.lemma)
    }

    // Returns the union of JMdict POS bits across every sense of every entry matching the surface.
    // Backed by the in-memory `surfacePOSBitsMap` populated at startup; no SQL at call time.
    // Falls back to the old SQL path only when the store isn't available.
    private func posBits(for surface: String) -> UInt64 {
        if let bits = dictionaryStore?.posBits(forSurface: surface), bits != 0 {
            return bits
        }
        return 0
    }

    // Resolves dictionary entries for one surface using script-aware lookup mode selection.
    func lookupEntries(for surface: String) -> [DictionaryEntry] {
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

    // Resolves all known readings for one lemma from the in-memory reading map or dictionary fallback.
    private func readingsForLemma(_ lemma: String) -> [String] {
        let trimmedLemma = lemma.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLemma.isEmpty == false else {
            return []
        }

        var readings: [String] = []
        var seenReadings = Set<String>()

        // Deduplicates readings for the lemma lookup path while preserving insertion order.
        func appendReading(_ reading: String?) {
            guard let reading, reading.isEmpty == false, seenReadings.contains(reading) == false else {
                return
            }

            seenReadings.insert(reading)
            readings.append(reading)
        }

        if let mapReadings = surfaceReadingData[trimmedLemma]?.readings {
            for reading in mapReadings {
                appendReading(reading)
            }
        }

        if ScriptClassifier.isPureKana(trimmedLemma) {
            appendReading(trimmedLemma)
            return readings
        }

        let entries = lookupLexeme(trimmedLemma, nil)
        for entry in entries where entry.kanjiForms.contains(where: { $0.text == trimmedLemma }) {
            for kanaForm in entry.kanaForms where kanaForm.nokanji == false {
                appendReading(kanaForm.text)
            }
        }

        return readings
    }

    // Resolves preferred reading for one lemma from the ordered reading candidates.
    private func readingForLemma(_ lemma: String) -> String? {
        readingsForLemma(lemma).first
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

    // Computes deinflection paths once and returns admitted, sorted lemma entries alongside the paths.
    // Depth is chain.count — a natural product of the BFS, not a separate computation.
    // Callers that need chain or transition data extract it from the returned paths without re-traversal.
    func admittedLemmasAndPaths(for surface: String) -> (lemmas: [(lemma: String, depth: Int)], paths: DeinflectionPathMap) {
        let trimmedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSurface.isEmpty == false else {
            return ([], [:])
        }

        let pathsByLemma = deinflector.deinflectionPaths(for: trimmedSurface)
        var admittedLemmaStrings = pathsByLemma.keys.filter { candidate in
            segmenter.resolvesSurface(candidate)
        }

        if admittedLemmaStrings.isEmpty && segmenter.resolvesSurface(trimmedSurface) {
            admittedLemmaStrings = [trimmedSurface]
        }

        // Build entries with depth directly from chain length — no separate computation step.
        var entries = admittedLemmaStrings.map { lemmaString in
            (lemma: lemmaString, depth: pathsByLemma[lemmaString]?.map { $0.chain.count }.min() ?? 0)
        }

        // POS-validity gate. Every deinflection rule's `kanaOut` terminates at a verb stem
        // (う, く, つ, る, …) or an adj-i ending (い), so every depth>0 candidate must, by
        // construction, be a verb or adjective in JMdict. When the candidate has JMdict
        // entries but none carry a verb/adjective POS, the chain that produced it is a
        // structural coincidence: the godan past rule kanaIn=った/kanaOut=う happens to
        // produce たう, which JMdict knows only as the noun 多雨 ("heavy rain"). Drop those.
        // Candidates with no JMdict entry at all are left alone — downstream lookup will
        // fall back to surface display rather than misattribute meaning.
        let validInflectableBits = PartOfSpeech.verb.bit | PartOfSpeech.adjective.bit
        entries.removeAll { entry in
            guard entry.depth > 0 else { return false }
            let candidatePOSBits = posBits(for: entry.lemma)
            guard candidatePOSBits != 0 else { return false }
            return (candidatePOSBits & validInflectableBits) == 0
        }

        // Reject mechanical-deeper paths whose chain passes through a shallower admitted lemma
        // that is itself a real JMdict entry. For 触れられない the deinflector reaches 触る at depth
        // 2 via "られない→る" then "れる→る", treating 触れる as if it were a godan-potential form
        // mid-chain — but 触れる is its own ichidan dictionary verb (`v1` posBits set), so the
        // re-interpretation as a potential of 触る is spurious. Without this gate the deeper 触る
        // wins by depth-descending sort and the lookup sheet shows さわ ruby plus no alternatives.
        // The check stays conservative: intermediates only count when they have direct JMdict
        // POS bits, so causative/passive chains like 食べさせられた → 食べる (whose 食べさせる /
        // 食べさせられる midpoints are deinflection-reachable but not standalone JMdict entries)
        // remain untouched.
        let admittedLemmaSet = Set(entries.map(\.lemma))
        var shadowedLemmas: Set<String> = []
        for entry in entries where entry.depth >= 2 {
            let candidateLemma = entry.lemma
            guard let paths = pathsByLemma[candidateLemma] else { continue }

            var isShadowed = false
            for path in paths {
                var intermediateSurface = trimmedSurface
                // Each path's last transition lands on the candidate lemma itself, so iterate the
                // prefix to inspect only the genuine intermediates.
                for transition in path.transitions.dropLast() {
                    guard intermediateSurface.hasSuffix(transition.kanaIn) else {
                        intermediateSurface = ""
                        break
                    }
                    let stem = intermediateSurface.dropLast(transition.kanaIn.count)
                    intermediateSurface = String(stem) + transition.kanaOut

                    if intermediateSurface != candidateLemma,
                       admittedLemmaSet.contains(intermediateSurface),
                       posBits(for: intermediateSurface) != 0 {
                        isShadowed = true
                        break
                    }
                }
                if isShadowed { break }
            }

            if isShadowed {
                shadowedLemmas.insert(candidateLemma)
            }
        }
        if shadowedLemmas.isEmpty == false {
            entries.removeAll { shadowedLemmas.contains($0.lemma) }
        }

        // Decide whether the surface is "definitely an inflected form" (in which case its
        // self-as-lemma candidate is noise) or "a lemma in its own right" (in which case any
        // deinflected candidates are coincidental and must not shadow it).
        //
        // Concretely: surfaces like 食べました deinflect to 食べる and should drop the
        // depth-0 self-entry — that's the intended behavior. But surfaces like ために are
        // themselves JMdict expression entries; they also coincidentally satisfy a verb
        // deinflection rule (ためぬ, classical negative of ためる), and without this guard the
        // depth>0 spurious match wins and the user sees ためぬ as the lemma.
        //
        // The discriminator is intentionally narrow: we only treat the surface as a set-
        // phrase lemma when JMdict tags an entry as `exp` (expression — a multi-token
        // idiom that, by convention, is not re-analyzed via deinflection rules). Codes
        // like `prt`, `conj`, `adv`, `cop` are too broad here — many of them are
        // homographs with valid verb conjugations (して is both a `conj` direct entry AND
        // the te-form of する; で is both a `prt` AND the te-form of だ). Suppressing
        // deinflection for those would lose the canonical verb lookup for the common case.
        // Expression-tagged surfaces (ために, 〜について, etc.) need the same in-memory POS
        // bits map used by the verb/adjective gate above. Going through lookupEntries here
        // re-issued SQL for every tap; the bit check is a single hashtable hit.
        let surfaceIsExpressionLemma = (posBits(for: trimmedSurface) & PartOfSpeech.expression.bit) != 0

        let preferredLemma = segmenter.preferredLemma(for: trimmedSurface)
        // The segmenter says the surface IS its own base form (e.g. adverbs たった, ずっと, きっと):
        // preserve the surface against any surviving spurious deinflection candidates.
        let surfaceIsItsOwnLemma = preferredLemma == trimmedSurface

        if surfaceIsExpressionLemma {
            // JMdict marks the surface as an expression idiom — purge all deinflected candidates
            // and ensure the surface itself is present as a depth-0 lemma.
            entries.removeAll { $0.depth > 0 }
            if entries.contains(where: { $0.lemma == trimmedSurface }) == false {
                entries.append((lemma: trimmedSurface, depth: 0))
            }
        } else if entries.contains(where: { $0.depth > 0 }) && surfaceIsItsOwnLemma == false {
            // Surface deinflects to something genuine and MeCab doesn't confirm it as a lemma —
            // treat surface as inflected and drop its self-entry.
            entries.removeAll { $0.lemma == trimmedSurface }
        }

        entries.sort { lhs, rhs in
            if preferredLemma == lhs.lemma && preferredLemma != rhs.lemma { return true }
            if preferredLemma == rhs.lemma && preferredLemma != lhs.lemma { return false }
            if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
            if lhs.lemma.count != rhs.lemma.count { return lhs.lemma.count > rhs.lemma.count }
            return lhs.lemma < rhs.lemma
        }

        return (entries, pathsByLemma)
    }

}
