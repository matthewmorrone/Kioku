import SwiftUI

// Renders the full-screen word detail screen shown from Words list rows.
// Major sections: title/header, kanji breakdown, definitions, alternate spellings, frequency, word list membership.
struct WordDetailView: View {
    let word: SavedWord
    let lists: [WordList]
    let dictionaryStore: DictionaryStore?
    // Default nil so the existing call site in WordsView compiles without change.
    let segmenter: Segmenter? = nil

    @State private var kanjiInfoByLiteral: [String: KanjiInfo] = [:]
    @State private var displayData: WordDisplayData? = nil
    @State private var sentencesExpanded: Bool = false
    @State private var wordComponents: [(surface: String, gloss: String?)] = []

    // Resolves the names of lists this word belongs to for display.
    private var membershipNames: [String] {
        let memberLists = lists.filter { word.wordListIDs.contains($0.id) }
        return memberLists.map(\.name).sorted()
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
        VStack(alignment: .leading, spacing: 0) {
            Text(word.surface)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)

            List {
                if kanjiCharacters.isEmpty == false {
                    Section("Kanji") {
                        ForEach(kanjiCharacters, id: \.self) { char in
                            if let info = kanjiInfoByLiteral[char] {
                                kanjiRow(info)
                            }
                        }
                    }
                }

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
                        Text(pos)
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

    // Returns spellings to surface as secondary display — excludes archaic and search-only forms.
    private func alternateSpellings(entry: DictionaryEntry) -> [String] {
        let surfaceIsKana = !ScriptClassifier.containsKanji(word.surface)
        if surfaceIsKana {
            return entry.kanjiForms
                .filter { form in
                    let info = form.info ?? ""
                    return !info.contains("oK") && !info.contains("sK")
                }
                .map(\.text)
        } else {
            let others = entry.kanaForms
                .filter { form in
                    let info = form.info ?? ""
                    return form.text != word.surface
                        && !info.contains("ok") && !info.contains("sk")
                }
                .map(\.text)
            return others.count > 1 ? others : []
        }
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

        let result = await Task.detached(priority: .userInitiated) {
            try? dictionaryStore.fetchWordDisplayData(entryID: entryID, surface: surface)
        }.value
        displayData = result

        guard let segmenter, result != nil else { return }
        let store = dictionaryStore
        let edges = segmenter.longestMatchEdges(for: surface)
        guard edges.count > 1 else { return }
        let components = await Task.detached(priority: .userInitiated) {
            edges.compactMap { edge -> (String, String?)? in
                let entries = try? store.lookup(surface: edge.surface, mode: .kanjiAndKana)
                let gloss = entries?.first?.senses.first?.glosses.first
                return (edge.surface, gloss)
            }
        }.value
        wordComponents = components
    }
}
