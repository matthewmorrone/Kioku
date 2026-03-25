import SwiftUI

// Renders the full-screen word detail screen shown from Words list rows.
// Major sections: title/header, definitions (all matching entries), alternate spellings, examples, components, kanji breakdown, word list membership.
struct WordDetailView: View {
    let word: SavedWord
    let dictionaryStore: DictionaryStore?
    // Default nil so the existing call site in WordsView compiles without change.
    let segmenter: Segmenter? = nil

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var wordListsStore: WordListsStore

    @AppStorage(TypographySettings.furiganaGapKey)
    private var furiganaGap = TypographySettings.defaultFuriganaGap

    // All entries matching the saved surface; saved entry is first.
    @State private var allDisplayData: [WordDisplayData] = []
    @State private var sentencesExpanded: Bool = false
    @State private var wordComponents: [(surface: String, gloss: String?)] = []

    // The saved entry is used for header, examples, alternates, and components.
    private var savedDisplayData: WordDisplayData? { allDisplayData.first }

    // Uses live store data so list membership and list names always reflect the current state.
    private var membershipNames: [String] {
        let liveIDs = wordsStore.words.first { $0.canonicalEntryID == word.canonicalEntryID }?.wordListIDs ?? word.wordListIDs
        return wordListsStore.lists.filter { liveIDs.contains($0.id) }.map(\.name).sorted()
    }


    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                let lemmaReading = savedDisplayData?.entry.kanaForms.first?.text
                let lemma = savedDisplayData?.entry.kanjiForms.first?.text
                // Derive the surface's reading from the lemma reading by swapping okurigana.
                // e.g. surface=届けたい, lemma=届ける, lemmaReading=とどける → surfaceReading=とどけたい
                let surfaceReading = deriveSurfaceReading(
                    surface: word.surface,
                    lemma: lemma,
                    lemmaReading: lemmaReading
                )
                let hasFurigana = ScriptClassifier.containsKanji(word.surface)
                    && surfaceReading != nil
                    && surfaceReading != word.surface

                if hasFurigana, let surfaceReading {
                    // Per-kanji-run furigana; kana okurigana portions carry no annotation.
                    FuriganaLabel(
                        surface: word.surface,
                        reading: surfaceReading,
                        font: .systemFont(ofSize: 34, weight: .bold),
                        gap: furiganaGap
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                } else {
                    Text(word.surface)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                }

                if let lemma, lemma != word.surface {
                    Text(lemma)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .offset(y: hasFurigana ? -8 : 0)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)

            List {
                // Single Definition section with all matching entries sorted most- to least-common.
                // Each entry's senses are preceded by an entry label + frequency tier.
                let sortedData = allDisplayData.sorted {
                    let a = FrequencyData(jpdbRank: $0.entry.jpdbRank, wordfreqZipf: $0.entry.wordfreqZipf).normalizedScore ?? -1
                    let b = FrequencyData(jpdbRank: $1.entry.jpdbRank, wordfreqZipf: $1.entry.wordfreqZipf).normalizedScore ?? -1
                    return a > b
                }
                if sortedData.isEmpty == false {
                    Section("Definition") {
                        ForEach(sortedData, id: \.entry.entryId) { data in
                            if data.entry.senses.isEmpty == false {
                                definitionSectionHeader(for: data.entry)
                                ForEach(Array(data.entry.senses.enumerated()), id: \.offset) { idx, sense in
                                    senseRow(number: idx + 1, sense: sense)
                                }
                                // Frequency tag chip after this entry's senses.
                                if let label = FrequencyData(jpdbRank: data.entry.jpdbRank, wordfreqZipf: data.entry.wordfreqZipf).frequencyLabel {
                                    Text(label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
                                        .listRowSeparator(.hidden)
                                        .padding(.bottom, 4)
                                }
                            }
                        }
                    }
                }

                // Alternate spellings — driven by saved entry only.
                if let entry = savedDisplayData?.entry {
                    let alternates = alternateSpellings(entry: entry)
                    if alternates.isEmpty == false {
                        Section("Also Written As") {
                            ForEach(alternates, id: \.self) { spelling in
                                HStack {
                                    Text(spelling)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if isUsuallyKana(entry: entry) {
                                        Text("usually kana")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }

                // Examples — driven by saved entry only.
                if let sentences = savedDisplayData?.sentences, sentences.isEmpty == false {
                    Section("Examples") {
                        let shown = sentencesExpanded ? sentences : Array(sentences.prefix(1))
                        ForEach(shown, id: \.japanese) { pair in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pair.japanese)
                                    .font(.subheadline)
                                Text(pair.english)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        if sentences.count > 1 {
                            Button(sentencesExpanded ? "Show fewer" : "Show \(sentences.count - 1) more…") {
                                sentencesExpanded.toggle()
                            }
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }

                // Components
                if wordComponents.isEmpty == false {
                    Section("Components") {
                        ForEach(wordComponents, id: \.surface) { component in
                            HStack {
                                Text(component.surface)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                if let gloss = component.gloss {
                                    Text(gloss)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }

                Section("Lists") {
                    if membershipNames.isEmpty {
                        Text("Unsorted")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(membershipNames, id: \.self) { name in
                            Text(name)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .task {
            await loadDisplayData()
        }
    }

    // Renders the entry label row showing the kanji form when it differs from the surface.
    // Only rendered when there is a distinct title to show — e.g. 良い for the surface いい.
    @ViewBuilder
    private func definitionSectionHeader(for entry: DictionaryEntry) -> some View {
        let entryTitle = entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text
        if let title = entryTitle, title != word.surface {
            Text(title)
                .font(.subheadline.weight(.medium))
                .listRowSeparator(.hidden)
                .padding(.bottom, 2)
        }
    }

    // Renders one numbered sense with POS label, gloss text, and subdued metadata tags.
    @ViewBuilder
    private func senseRow(number: Int, sense: DictionaryEntrySense) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    if let pos = sense.pos, pos.isEmpty == false {
                        Text(JMdictTagExpander.expandAll(pos))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    Text(sense.glosses.joined(separator: "; "))
                        .font(.subheadline)
                }
            }

            let tags = [sense.misc, sense.field, sense.dialect]
                .compactMap { $0 }
                .filter { $0.isEmpty == false }
                .map { JMdictTagExpander.expandAll($0) }
            if tags.isEmpty == false {
                HStack(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }

    // Derives the reading for the actual saved surface from the dictionary lemma's reading.
    // When the surface is an inflected form (e.g. 近づいて from lemma 近づく), the lemma's kana
    // reading (ちかずく) uses a different okurigana than the surface (づいて). We cannot match
    // the lemma okurigana string against the reading because historical kana spellings differ
    // (づく in surface vs ずく in reading). Instead we use character counts: the kanji-run
    // characters in the lemma tell us how many kana to keep from the front of the lemma reading
    // as the kanji stem, then append the surface's own kana suffix.
    private func deriveSurfaceReading(surface: String, lemma: String?, lemmaReading: String?) -> String? {
        guard let lemmaReading else { return nil }
        guard let lemma, lemma != surface else { return lemmaReading }

        let lemmaOkurigana = kanaSuffix(of: lemma)
        let surfaceOkurigana = kanaSuffix(of: surface)

        // Nothing to do when okurigana already match.
        guard lemmaOkurigana != surfaceOkurigana else { return lemmaReading }

        // Count kanji characters in the lemma to determine how many kana begin the reading.
        // The reading encodes kanji-run pronunciation first, then okurigana at the end.
        // We strip exactly lemmaOkurigana.count characters from the end of the reading,
        // regardless of whether the kana glyphs match (they may differ in historical spelling).
        if !lemmaOkurigana.isEmpty, lemmaReading.count > lemmaOkurigana.count {
            let stemEndIndex = lemmaReading.index(lemmaReading.endIndex, offsetBy: -lemmaOkurigana.count)
            let kanjiStemReading = String(lemmaReading[..<stemEndIndex])
            return kanjiStemReading + surfaceOkurigana
        }

        return lemmaReading
    }

    // Returns the trailing kana-only suffix of a string (the okurigana after the last kanji).
    private func kanaSuffix(of text: String) -> String {
        var suffix = ""
        for char in text.reversed() {
            let s = String(char)
            if ScriptClassifier.containsKanji(s) { break }
            suffix = s + suffix
        }
        return suffix
    }

    // Returns spellings to surface as secondary display — excludes archaic and search-only forms.
    // Kana surfaces are excluded entirely: a kana reading maps to many possible kanji, so
    // surfacing one entry's kanji forms implies a false uniqueness.
    private func alternateSpellings(entry: DictionaryEntry) -> [String] {
        guard ScriptClassifier.containsKanji(word.surface) else { return [] }

        let others = entry.kanaForms
            .filter { form in
                let info = form.info ?? ""
                return form.text != word.surface
                    && !info.contains("ok") && !info.contains("sk")
            }
            .map(\.text)
        return others.count > 1 ? others : []
    }

    // Returns true when the entry flags the word as usually written in kana alone.
    private func isUsuallyKana(entry: DictionaryEntry) -> Bool {
        entry.senses.contains { ($0.misc ?? "").contains("uk") }
    }

    // Fetches display data for all entries matching the saved surface, placing the saved entry first.
    // This ensures all homophone entries are shown while keeping the saved entry's context primary.
    private func loadDisplayData() async {
        guard let dictionaryStore else { return }
        let surface = word.surface
        let savedEntryID = word.canonicalEntryID

        let results = await Task { @MainActor in
            // Look up all entries matching the surface.
            let lookupMode: LookupMode = ScriptClassifier.containsKanji(surface) ? .kanjiAndKana : .kanaOnly
            let entries = (try? dictionaryStore.lookup(surface: surface, mode: lookupMode)) ?? []

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

        guard let segmenter, results.isEmpty == false else { return }
        let store = dictionaryStore
        let edges = segmenter.longestMatchEdges(for: surface)
        guard edges.count > 1 else { return }
        let components = await Task { @MainActor in
            edges.compactMap { edge -> (String, String?)? in
                let entries = try? store.lookup(surface: edge.surface, mode: .kanjiAndKana)
                let gloss = entries?.first?.senses.first?.glosses.first
                return (edge.surface, gloss)
            }
        }.value
        wordComponents = components
    }
}
