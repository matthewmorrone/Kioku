import SwiftUI

// Data-loading and presentation helpers for WordDetailView: the live saved-word lookup,
// the async display-data/related-words/conjugation loader, reading inflection, and the
// small reusable row/label view builders. Extracted from WordDetailView so the primary
// file stays under the line-count invariant.
extension WordDetailView {
    // SF Symbol for the header's save/learned toggle: a plain checkmark when learned, a plain
    // question mark when explicitly not-learned, else the save star (filled when saved). Mirrors
    // the row's learnedIcon so the same mark reads identically in the list and the detail header.
    func detailLearnedIcon(state: LearnedState, saved: Bool) -> String {
        switch state {
        case .learned:    return "checkmark"
        case .notLearned: return "questionmark"
        case .unmarked:   return saved ? "star.fill" : "star"
        }
    }

    // Reads the live saved word from the store so the picker reflects toggled state immediately.
    // Falls back to the SavedWord the view was opened with for the brief window before the store
    // publish reaches @EnvironmentObject.
    var currentSavedWord: SavedWord {
        wordsStore.words.first { $0.canonicalEntryID == activeEntryID } ?? word
    }
    var currentSelectedSenseIDs: [Int64] { currentSavedWord.selectedSenseIDs }
    var currentSelectedGlosses: [GlossRef] { currentSavedWord.selectedGlosses }

    // Delegates to the unit-tested WordVariants helper. Surfaces both kanji and
    // kana alternates for kanji-bearing saved surfaces; returns [] for pure-kana
    // surfaces (see WordVariants for the rationale and filter rules).
    func alternateSpellings(entry: DictionaryEntry) -> [String] {
        WordVariants.alternateSpellings(savedSurface: word.surface, entry: entry)
    }

    // Returns true when the entry flags the word as usually written in kana alone.
    func isUsuallyKana(entry: DictionaryEntry) -> Bool {
        entry.senses.contains { ($0.misc ?? "").contains("uk") }
    }

    // Fetches display data for all entries matching the saved surface, placing the saved entry first.
    // This ensures all homophone entries are shown while keeping the saved entry's context primary.
    func loadDisplayData() async {
        guard let dictionaryStore else { return }
        let surface = word.surface
        let savedEntryID = activeEntryID

        let results = await Task { @MainActor in
            // Look up all entries matching the surface in both kanji and kana columns. The
            // earlier script-conditional mode was a no-op micro-optimization — a pure-kana
            // surface can never match a kanji column, so .kanjiAndKana and .kanaOnly are
            // functionally identical for kana surfaces. The conditional was misleading.
            let entries = (try? dictionaryStore.lookup(surface: surface, mode: .kanjiAndKana)) ?? []

            // Build display data for each entry, saved entry first.
            var ordered: [WordDisplayData] = []
            var rest: [WordDisplayData] = []
            for entry in entries {
                if let data = try? dictionaryStore.fetchWordDisplayData(entryID: entry.entryId, surface: surface) {
                    if entry.entryId == savedEntryID {
                        ordered.insert(data, at: 0)
                    } else {
                        rest.append(data)
                    }
                }
            }
            // If saved entry wasn't in the lookup results, fetch it directly.
            if ordered.isEmpty {
                if let data = try? dictionaryStore.fetchWordDisplayData(entryID: savedEntryID, surface: surface) {
                    ordered.append(data)
                }
            }
            return ordered + rest
        }.value

        allDisplayData = results

        guard results.isEmpty == false else { return }
        let store = dictionaryStore

        // Analyze the dictionary base form, not the (possibly inflected) saved surface, so the
        // derivation rules match conjugated saves too (生まれた → 生まれる, 生きてゆいた → 生きてゆく).
        // Use the saved surface when it is itself a base form; otherwise fall back to the entry's
        // primary kanji/kana headword.
        let analysisForm: String = {
            guard let entry = results.first?.entry else { return surface }
            let forms = entry.kanjiForms.map(\.text) + entry.kanaForms.map(\.text)
            if forms.contains(surface) { return surface }
            return entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? surface
        }()

        // Fetch components and sublattice paths via segmenter when available.
        if let segmenter {
            let result = segmenter.longestMatchResult(for: surface)
            // Per-position lemmas of the chosen path, reused for compound-verb derivation detection.
            let componentLemmas = result.selectedEdges.map { $0.lemma.isEmpty ? $0.surface : $0.lemma }

            // Derivation description for the header — names the base word + affix for derived
            // forms (弱さ, お酒, 生まれる, 生きてゆく). The resolver hands the analyzer the JMdict POS
            // tags of any candidate lemma so it can confirm and label the base. nil → plain POS line.
            let derivation = await Task { @MainActor in
                DerivationAnalyzer.analyze(surface: analysisForm, components: componentLemmas, baseResolver: { lemma in
                    let entries = (try? store.lookup(surface: lemma, mode: .kanjiAndKana)) ?? []
                    return entries.flatMap { $0.senses.compactMap(\.pos) }
                        .flatMap { $0.components(separatedBy: ",") }
                })
            }.value
            derivationSummary = derivation?.summary

            // Compound word breakdown uses the selected (best) path. Each component looks up
            // by the segmenter-resolved lemma when one is available — `edge.surface` alone
            // produces wrong defaults for short surfaces (e.g. 生 returns 生る/なる first
            // even when the path resolved this position to 生きる).
            if result.selectedEdges.count > 1 {
                let components = await Task { @MainActor in
                    result.selectedEdges.compactMap { edge -> (String, String?)? in
                        let lookupSurface = edge.lemma.isEmpty ? edge.surface : edge.lemma
                        let entries = try? store.lookup(surface: lookupSurface, mode: .kanjiAndKana)
                        let gloss = entries?.first?.senses.first?.glosses.first
                        return (lookupSurface, gloss)
                    }
                }.value
                wordComponents = components
            }

            // Use pre-computed paths from the lookup sheet; fall back to computing from the segmenter.
            if initialSublatticePaths.isEmpty {
                sublatticePaths = LatticeEdge.validPaths(from: result.latticeEdges)
            } else {
                sublatticePaths = initialSublatticePaths
            }
        }

        // Fetch kanji breakdown for each unique kanji character in the surface.
        let uniqueKanji = word.surface
            .map(String.init)
            .filter { ScriptClassifier.containsKanji($0) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let infos = await Task { @MainActor in
            uniqueKanji.compactMap { try? store.fetchKanjiInfo(for: $0) }
        }.value
        kanjiInfos = infos

        // Related words — other entries sharing the headword's primary (first) kanji, ranked
        // by frequency. Approximates the reference's kanji-family "Related Words" list.
        // Excludes the saved entry and any entry whose kanji form is exactly the saved surface.
        if let primaryKanji = uniqueKanji.first {
            let savedID = activeEntryID
            let savedSurface = word.surface
            let related = await Task { @MainActor in
                (try? store.searchEntriesContainingKanji(literal: primaryKanji, limit: 40)) ?? []
            }.value
            relatedEntries = Array(
                related
                    .filter { $0.entryId != savedID }
                    .filter { entry in entry.kanjiForms.contains { $0.text == savedSurface } == false }
                    .prefix(30)
            )
        }

        // Fetch cross-references, antonyms, and loanword origins for the saved entry.
        let savedID = activeEntryID
        let sources = await Task { @MainActor in
            (try? store.fetchLoanwordSources(entryID: savedID)) ?? []
        }.value
        loanwordSources = sources

        let refs = await Task { @MainActor in
            (try? store.fetchSenseReferences(entryID: savedID)) ?? []
        }.value
        senseReferences = refs

        // Synonyms — resolve the saved entry's JMdict cross-references (xref "see also" links)
        // to full dictionary entries so they can be shown as their own browsable section. The
        // target may be a bare word or "word・reading・senseNum"; the leading element before the
        // first middle dot is the headword to look up. Entries already shown among the kanji-family
        // related words (and the saved entry itself) are skipped so nothing appears twice.
        let xrefHeads = refs
            .filter { $0.type == .xref }
            .map { String($0.target.split(separator: "・").first ?? "") }
            .filter { $0.isEmpty == false }
        if xrefHeads.isEmpty {
            synonymEntries = []
        } else {
            let excluded = Set(relatedEntries.map(\.entryId)).union([savedID])
            synonymEntries = await Task { @MainActor in
                var seen = excluded
                var resolved: [DictionaryEntry] = []
                for head in xrefHeads {
                    let matches = (try? store.lookup(surface: head, mode: .kanjiAndKana)) ?? []
                    guard let first = matches.first, seen.insert(first.entryId).inserted else { continue }
                    resolved.append(first)
                    if resolved.count >= 12 { break }
                }
                return resolved
            }.value
        }

        // Compute conjugation groups for verbs or i-adjectives — conjugates against the surface the
        // user saved so kana-only saves (e.g., じゃない) don't get promoted to a canonical kanji form.
        if let vc = verbClass {
            conjugationGroups = VerbConjugator.conjugationGroups(for: word.surface, verbClass: vc)
        } else if isIAdjective {
            conjugationGroups = VerbConjugator.adjectiveConjugationGroups(for: word.surface)
        }
    }

    // Maps ISO 639-2/B language codes to display names for common loanword source languages.
    func languageName(for code: String) -> String {
        let map: [String: String] = [
            "eng": "English", "fre": "French", "ger": "German",
            "por": "Portuguese", "dut": "Dutch", "ita": "Italian",
            "spa": "Spanish", "rus": "Russian", "chi": "Chinese",
            "kor": "Korean", "san": "Sanskrit", "ara": "Arabic",
        ]
        return map[code] ?? code.uppercased()
    }

    // Derives the inflected reading for the surface from the entry's base forms.
    // When the surface is an inflected form (e.g. 流れた) and the entry stores the base form
    // (流れる / ながれる), the base-form reading can't project onto the inflected surface because
    // the okurigana differ (た vs る). This function finds the common prefix between the base
    // kanji form and the surface, then replaces the base suffix in the reading with the surface's suffix.
    // Returns the base reading unchanged when prefix matching fails or the entry is nil.
    func inflectedReading(surface: String, entry: DictionaryEntry?) -> String? {
        guard let entry else { return nil }
        let baseReading = entry.kanaForms.first?.text
        guard let baseReading else { return nil }

        // If the surface matches a kanji or kana form exactly, no inflection adjustment needed.
        let isBaseForm = entry.kanjiForms.contains { $0.text == surface }
            || entry.kanaForms.contains { $0.text == surface }
        if isBaseForm { return baseReading }

        // Try each kanji form to find one that shares a prefix with the surface.
        for kanjiForm in entry.kanjiForms {
            let base = Array(kanjiForm.text)
            let surf = Array(surface)
            let prefixLen = zip(base, surf).prefix(while: { $0 == $1 }).count
            guard prefixLen > 0, prefixLen < base.count, prefixLen < surf.count else { continue }

            let baseSuffix = String(base[prefixLen...])
            let surfaceSuffix = String(surf[prefixLen...])

            // The reading should end with the base form's kana suffix.
            if baseReading.hasSuffix(baseSuffix) {
                let readingPrefix = baseReading.dropLast(baseSuffix.count)
                return readingPrefix + surfaceSuffix
            }
        }

        // Fallback: return the base reading and let the header do its best.
        return baseReading
    }

    // Renders a small pill-shaped metadata chip used across multiple sections.
    @ViewBuilder
    func metadataLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
    }

    // One related-word row: an optional structural-relationship badge, the POS label, the
    // surface + reading, and the leading glosses — the same at-a-glance information the
    // reference shows for each related entry. `relationLabel` is non-nil for the structural
    // entries ordered first in the Related Words list, where it names the trans/intrans pair
    // or same-stem form.
    @ViewBuilder
    func relatedWordRow(_ entry: DictionaryEntry, relationLabel: String? = nil) -> some View {
        let surface = entry.firstEverydayKanji?.text ?? entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? ""
        let reading = entry.kanaForms.first?.text
        let firstSense = entry.senses.first
        let posLabel: String? = {
            guard let pos = firstSense?.pos, pos.isEmpty == false else { return nil }
            return pos.components(separatedBy: ",")
                .filter { $0.isEmpty == false }
                .map { Self.titleCased(JMdictTagExpander.expand($0)) }
                .joined(separator: " · ")
        }()
        let glossText = (firstSense?.glosses ?? []).prefix(3).joined(separator: ", ")

        VStack(alignment: .leading, spacing: 2) {
            if let relationLabel {
                Text(relationLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            if let posLabel {
                Text(posLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(surface)
                    .font(.body.weight(.medium))
                if let reading, reading != surface {
                    Text(reading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            if glossText.isEmpty == false {
                Text(glossText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // Compact tappable row content for one kanji character — extracted so the Kanji section
    // can wrap it in a Button without duplicating the layout.
    @ViewBuilder
    func kanjiRowContent(_ info: KanjiInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Center the large glyph against the meanings + metadata block (the first two
            // rows) rather than baseline-aligning it to the meanings row alone.
            HStack(alignment: .center, spacing: 10) {
                Text(info.literal)
                    .font(.system(size: 28, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text(info.meanings.prefix(3).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    HStack(spacing: 8) {
                        if let grade = info.grade {
                            metadataLabel(grade == 8 ? "Secondary" : "Grade \(grade)")
                        }
                        if let jlpt = info.jlptLevel {
                            metadataLabel("JLPT N\(jlpt)")
                        }
                        if let strokes = info.strokeCount {
                            metadataLabel("\(strokes) strokes")
                        }
                    }
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if info.onReadings.isEmpty == false {
                HStack(spacing: 4) {
                    Text("ON")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(info.onReadings.joined(separator: "・"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if info.kunReadings.isEmpty == false {
                HStack(spacing: 4) {
                    Text("KUN")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(info.kunReadings.joined(separator: "・"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
