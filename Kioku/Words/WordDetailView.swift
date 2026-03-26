import SwiftUI

// Renders the full-screen word detail screen shown from Words list rows.
// Major sections: title/header, definitions, alternate spellings, frequency, examples, components, kanji breakdown, word list membership.
struct WordDetailView: View {
    let word: SavedWord
    let dictionaryStore: DictionaryStore?
    // Default nil so the existing call site in WordsView compiles without change.
    let segmenter: Segmenter? = nil

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var wordListsStore: WordListsStore

    @State private var kanjiInfoByLiteral: [String: KanjiInfo] = [:]
    @State private var displayData: WordDisplayData? = nil
    @State private var sentencesExpanded: Bool = false
    @State private var wordComponents: [(surface: String, gloss: String?)] = []
    @State private var kanjiExpanded: Bool = false

    // Uses live store data so list membership and list names always reflect the current state.
    private var membershipNames: [String] {
        let liveIDs = wordsStore.words.first { $0.canonicalEntryID == word.canonicalEntryID }?.wordListIDs ?? word.wordListIDs
        return wordListsStore.lists.filter { liveIDs.contains($0.id) }.map(\.name).sorted()
    }

    // Extracts unique kanji scalars from the surface in source order.
    private var kanjiCharacters: [String] {
        var seen = Set<String>()
        return word.surface.unicodeScalars.compactMap { scalar in
            let value = scalar.value
            guard (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) else {
                return nil
            }
            let char = String(scalar)
            guard seen.insert(char).inserted else { return nil }
            return char
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                let lemmaReading = displayData?.entry.kanaForms.first?.text
                let lemma = displayData?.entry.kanjiForms.first?.text
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
                        font: .systemFont(ofSize: 34, weight: .bold)
                    )
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
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)

            List {
                // Definitions section
                if let entry = displayData?.entry, entry.senses.isEmpty == false {
                    Section("Definition") {
                        ForEach(Array(entry.senses.enumerated()), id: \.offset) { idx, sense in
                            senseRow(number: idx + 1, sense: sense)
                        }
                    }
                }

                // Alternate spellings
                if let entry = displayData?.entry {
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

                // Frequency
                if let entry = displayData?.entry,
                   entry.jpdbRank != nil || entry.wordfreqZipf != nil {
                    Section("Frequency") {
                        if let rank = entry.jpdbRank {
                            LabeledContent("JPDB Rank", value: "#\(rank)")
                                .font(.subheadline)
                        }
                        if let zipf = entry.wordfreqZipf {
                            LabeledContent("Zipf Score", value: String(format: "%.2f", zipf))
                                .font(.subheadline)
                        }
                    }
                }

                // Examples
                if let sentences = displayData?.sentences, sentences.isEmpty == false {
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

                // Kanji breakdown — collapsed by default to keep definitions front and center.
                if kanjiCharacters.isEmpty == false {
                    Section {
                        DisclosureGroup(isExpanded: $kanjiExpanded) {
                            ForEach(kanjiCharacters, id: \.self) { char in
                                if let info = kanjiInfoByLiteral[char] {
                                    kanjiRow(info)
                                }
                            }
                        } label: {
                            Text("Kanji")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
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
            async let kanjiLoad: Void = loadKanjiInfo()
            async let displayLoad: Void = loadDisplayData()
            _ = await (kanjiLoad, displayLoad)
        }
    }

    // Renders one kanji character with its on/kun readings, meanings, and learner metadata.
    @ViewBuilder
    private func kanjiRow(_ info: KanjiInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                Text(info.literal)
                    .font(.system(size: 36, weight: .light))
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 3) {
                    if info.onReadings.isEmpty == false {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("音")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(info.onReadings.joined(separator: "・"))
                                .font(.subheadline)
                        }
                    }

                    if info.kunReadings.isEmpty == false {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("訓")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(info.kunReadings.joined(separator: "・"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if info.meanings.isEmpty == false {
                        Text(info.meanings.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    if let strokes = info.strokeCount {
                        Text("\(strokes) strokes")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if let jlpt = info.jlptLevel {
                        Text("N\(jlpt)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // Renders one numbered sense with POS label, gloss text, and subdued metadata tags.
    @ViewBuilder
    private func senseRow(number: Int, sense: DictionaryEntrySense) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    if let pos = sense.pos, pos.isEmpty == false {
                        Text(JMdictTagExpander.expand(pos))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
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

    // Loads KANJIDIC2 data for each kanji character in the surface off the main thread.
    private func loadKanjiInfo() async {
        guard let dictionaryStore, kanjiCharacters.isEmpty == false else { return }

        let characters = kanjiCharacters
        let result = await Task.detached(priority: .userInitiated) {
            var loaded: [String: KanjiInfo] = [:]
            for char in characters {
                if let info = try? await MainActor.run(body: { try dictionaryStore.fetchKanjiInfo(for: char) }) {
                    loaded[char] = info
                }
            }
            return loaded
        }.value

        kanjiInfoByLiteral = result
    }

    // Fetches the full word display bundle and word components off the main thread.
    private func loadDisplayData() async {
        guard let dictionaryStore else { return }
        let surface = word.surface
        let entryID = word.canonicalEntryID

        let store = dictionaryStore
        let result = await Task.detached(priority: .userInitiated) {
            try? store.fetchWordDisplayData(entryID: entryID, surface: surface)
        }.value
        displayData = result

        guard let segmenter, result != nil else { return }
        let store2 = dictionaryStore
        let edges = segmenter.longestMatchEdges(for: surface)
        guard edges.count > 1 else { return }
        let components = await Task.detached(priority: .userInitiated) {
            edges.compactMap { edge -> (String, String?)? in
                let entries = try? store2.lookup(surface: edge.surface, mode: .kanjiAndKana)
                let gloss = entries?.first?.senses.first?.glosses.first
                return (edge.surface, gloss)
            }
        }.value
        wordComponents = components
    }
}
