import SwiftUI

// Renders the full-screen word detail screen shown from Words list rows.
// Major sections: title/header (furigana + lemma), definitions (all matching entries), alternate spellings, examples, components.
struct WordDetailView: View {
    let word: SavedWord
    // Reading resolved by the lookup sheet at save time — matches furigana shown there exactly.
    // Nil when opened directly from the words list (not via lookup sheet).
    let reading: String?
    let dictionaryStore: DictionaryStore?
    // Default nil so the existing call site in WordsView compiles without change.
    let segmenter: (any TextSegmenting)? = nil

    // Provides per-word review statistics keyed by canonicalEntryID.
    @EnvironmentObject private var reviewStore: ReviewStore
    // Provides the list of all user-created word lists so membership can be displayed.
    @EnvironmentObject private var wordListsStore: WordListsStore

    // All entries matching the saved surface; saved entry is first.
    @State private var allDisplayData: [WordDisplayData] = []
    @State private var sentencesExpanded: Bool = false
    @State private var wordComponents: [(surface: String, gloss: String?)] = []
    @State private var kanjiInfos: [KanjiInfo] = []
    @State private var loanwordSources: [LoanwordSource] = []
    @State private var senseReferences: [SenseReference] = []
    @State private var showingConjugations: Bool = false
    @State private var conjugationGroups: [ConjugationGroup] = []

    // The saved entry is used for header, examples, alternates, and components.
    private var savedDisplayData: WordDisplayData? { allDisplayData.first }

    // Returns true when the saved entry is flagged as a common word in JMdict priority data.
    // Checks all kanji and kana forms for ichi1/news1/spec1 priority tags.
    private var isCommonWord: Bool {
        guard let entry = savedDisplayData?.entry else { return false }
        let priorities = (entry.kanjiForms.map(\.priority) + entry.kanaForms.map(\.priority))
            .compactMap { $0 }
        return priorities.contains { $0.contains("ichi1") || $0.contains("news1") || $0.contains("spec1") }
    }

    // Returns the verb class detected from the saved entry's POS tags, or nil for non-verbs.
    // Used to decide whether to show the Forms section.
    private var verbClass: VerbClass? {
        guard let entry = savedDisplayData?.entry else { return nil }
        let posTags = entry.senses.compactMap(\.pos).flatMap { $0.components(separatedBy: ",") }
        return VerbConjugator.detectVerbClass(fromJMDictPosTags: posTags)
    }

    // Static set of known grammaticalized auxiliary verb surfaces — hoisted to avoid allocating on every call.
    private static let auxiliaryComponents: Set<String> = [
        "続ける", "始める", "終わる", "出す", "込む", "合う", "切る",
        "もらう", "あげる", "くれる", "いく", "くる", "おく", "みる",
        "しまう", "ある", "いる", "させる", "もらえる",
    ]

    // Returns true when a component surface is a grammaticalized auxiliary verb in this compound context.
    // These are ichidan verbs that function as aspect/voice markers when suffixed to a masu-stem.
    // Checked by exact match against known auxiliary surfaces.
    private func isAuxiliaryComponent(_ surface: String) -> Bool {
        Self.auxiliaryComponents.contains(surface)
    }

    var body: some View {
        VStack(spacing: 0) {
            let entry = savedDisplayData?.entry
            // Use the reading passed from the lookup sheet when available; fall back to the
            // entry's primary kana form so the header still shows furigana for words opened
            // directly from the words list.
            let surfaceReading = reading ?? entry?.kanaForms.first?.text
            // Show lemma only when the surface is an inflected form — i.e. not present in the
            // entry's own kanji or kana forms. Mirrors the lookup sheet's lemma visibility rule.
            let surfaceIsBaseForm = entry?.kanjiForms.contains(where: { $0.text == word.surface }) == true
                || entry?.kanaForms.contains(where: { $0.text == word.surface }) == true
            let lemma = surfaceIsBaseForm ? nil : entry?.kanjiForms.first?.text
            SegmentLookupSheetHeader(
                surface: word.surface,
                reading: surfaceReading,
                lemma: lemma
            )
            .frame(maxWidth: .infinity)
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
                        if wordComponents.isEmpty == false {
                            // Compound word: one card per component showing that component's definition.
                            ForEach(wordComponents, id: \.surface) { component in
                                VStack(alignment: .leading, spacing: 0) {
                                    // Component label row with optional auxiliary badge.
                                    HStack(spacing: 6) {
                                        Text(component.surface)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        if isAuxiliaryComponent(component.surface) {
                                            Text("auxiliary")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(Color.purple)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                        }
                                    }
                                    .padding(.bottom, 4)

                                    if let gloss = component.gloss {
                                        Text(gloss)
                                            .font(.subheadline)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        } else {
                            // Single entry: standard sense rows.
                            ForEach(sortedData, id: \.entry.entryId) { data in
                                if data.entry.senses.isEmpty == false {
                                    definitionSectionHeader(for: data.entry)
                                    let freqLabel = FrequencyData(jpdbRank: data.entry.jpdbRank, wordfreqZipf: data.entry.wordfreqZipf).frequencyLabel
                                    ForEach(Array(data.entry.senses.enumerated()), id: \.offset) { idx, sense in
                                        // Cross-references are fetched only for the saved entry; pass empty refs for other entries.
                                        let senseRefs = data.entry.entryId == word.canonicalEntryID
                                            ? senseReferences.filter { $0.senseOrderIndex == idx }
                                            : []
                                        // Frequency label is shown inline in the first sense only — it is an entry-level attribute.
                                        senseRow(number: idx + 1, sense: sense, refs: senseRefs, freqLabel: idx == 0 ? freqLabel : nil, showNumber: data.entry.senses.count > 1)
                                    }
                                }
                            }
                        }
                    }
                }

                // Forms section — shown for verbs only. Displays te-form / negative / past inline,
                // with an "All conjugations" row that opens ConjugationSheetView.
                if let vc = verbClass,
                   let dictionaryForm = savedDisplayData?.entry.kanjiForms.first?.text
                                     ?? savedDisplayData?.entry.kanaForms.first?.text {
                    let keyForms = VerbConjugator.keyForms(for: dictionaryForm, verbClass: vc)
                    if keyForms.isEmpty == false {
                        Section("Forms") {
                            ForEach(keyForms, id: \.label) { form in
                                HStack {
                                    Text(form.surface)
                                        .foregroundStyle(Color.accentColor)
                                    Spacer()
                                    Text(form.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Button {
                                showingConjugations = true
                            } label: {
                                HStack {
                                    Text("All conjugations")
                                        .foregroundStyle(Color.accentColor)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
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
                    let shown = sentencesExpanded ? sentences : Array(sentences.prefix(1))
                    Section("Examples") {
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

                // Kanji breakdown — one row per unique kanji character found in the surface.
                if kanjiInfos.isEmpty == false {
                    Section("Kanji") {
                        ForEach(kanjiInfos, id: \.literal) { info in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(info.literal)
                                        .font(.system(size: 28, weight: .medium))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(info.meanings.prefix(3).joined(separator: ", "))
                                            .font(.subheadline)

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
                        }
                    }
                }

                // Loanword origin section — shown only when the entry has JMdict lsource data.
                if loanwordSources.isEmpty == false {
                    Section("Origin") {
                        ForEach(Array(loanwordSources.enumerated()), id: \.offset) { _, source in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let sourceWord = source.content, sourceWord.isEmpty == false {
                                        Text(sourceWord)
                                            .font(.subheadline.weight(.medium))
                                    }
                                    Text(languageName(for: source.lang))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if source.wasei {
                                    metadataLabel("wasei")
                                }
                                if source.lsType == .part {
                                    metadataLabel("partial")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // Pitch Accent section — uses data already present in WordDisplayData.
                // Uses offset as the id because multiple entries can share the same kana value.
                if let pitchAccents = savedDisplayData?.pitchAccents, pitchAccents.isEmpty == false {
                    Section("Pitch Accent") {
                        ForEach(Array(pitchAccents.enumerated()), id: \.offset) { _, pa in
                            PitchAccentView(accent: pa)
                        }
                    }
                }

                // Review statistics section — always shown; "Not yet reviewed" for words never studied.
                Section("Review") {
                    if let stats = reviewStore.stats[word.canonicalEntryID] {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Correct")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(stats.correct)")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                            VStack(alignment: .center, spacing: 2) {
                                Text("Again")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(stats.again)")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.red)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Accuracy")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let acc = stats.accuracy {
                                    Text("\(Int(acc * 100))%")
                                        .font(.title3.weight(.semibold))
                                } else {
                                    Text("—")
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        if let lastReviewed = stats.lastReviewedAt {
                            HStack {
                                Text("Last reviewed")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(lastReviewed, style: .relative)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    } else {
                        Text("Not yet reviewed")
                            .foregroundStyle(.secondary)
                    }
                }

                // Save date and word list membership — always shown for context on when and how the word was saved.
                Section("Saved") {
                    HStack {
                        Text("Added")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(word.savedAt, style: .date)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    // Resolve list objects from IDs so the user sees human-readable labels keyed by stable UUID.
                    let memberLists = wordListsStore.lists
                        .filter { word.wordListIDs.contains($0.id) }
                        .sorted { $0.name < $1.name }
                    ForEach(memberLists, id: \.id) { list in
                        Label(list.name, systemImage: "list.bullet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

            }
            .listStyle(.insetGrouped)
            .sheet(isPresented: $showingConjugations) {
                if verbClass != nil,
                   let dictionaryForm = savedDisplayData?.entry.kanjiForms.first?.text
                                     ?? savedDisplayData?.entry.kanaForms.first?.text {
                    ConjugationSheetView(
                        dictionaryForm: dictionaryForm,
                        groups: conjugationGroups,
                        onLookup: { _ in
                            // Tapping a conjugated form — lookup integration is a future task.
                            showingConjugations = false
                        }
                    )
                    .presentationDetents([.large])
                }
            }
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

    // Renders one sense with POS label, gloss, metadata tags, and optional cross-references.
    // showNumber: pass false when the entry has only one sense — the number adds no information.
    // freqLabel is non-nil only for the first sense of an entry.
    @ViewBuilder
    private func senseRow(number: Int, sense: DictionaryEntrySense, refs: [SenseReference] = [], freqLabel: String? = nil, showNumber: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showNumber {
                    Text("\(number).")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let pos = sense.pos, pos.isEmpty == false {
                            Text(JMdictTagExpander.expandAll(pos))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        if let label = freqLabel {
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
                        }
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
                .padding(.leading, showNumber ? 24 : 0)
            }

            // Cross-references and antonyms for this sense.
            let xrefs = refs.filter { $0.type == .xref }.map(\.target)
            let ants  = refs.filter { $0.type == .ant  }.map(\.target)
            if xrefs.isEmpty == false {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("See also:")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(xrefs.joined(separator: "、"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, showNumber ? 24 : 0)
            }
            if ants.isEmpty == false {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Antonym:")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(ants.joined(separator: "、"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, showNumber ? 24 : 0)
            }
        }
        .padding(.vertical, 2)
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

        guard results.isEmpty == false else { return }
        let store = dictionaryStore

        // Fetch components via segmenter when available (compound words only).
        if let segmenter {
            let edges = segmenter.longestMatchEdges(for: surface)
            if edges.count > 1 {
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

        // Fetch kanji breakdown for each unique kanji character in the surface.
        let uniqueKanji = word.surface
            .map(String.init)
            .filter { ScriptClassifier.containsKanji($0) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let infos = await Task { @MainActor in
            uniqueKanji.compactMap { try? store.fetchKanjiInfo(for: $0) }
        }.value
        kanjiInfos = infos

        // Fetch cross-references, antonyms, and loanword origins for the saved entry.
        let savedID = word.canonicalEntryID
        let sources = await Task { @MainActor in
            (try? store.fetchLoanwordSources(entryID: savedID)) ?? []
        }.value
        loanwordSources = sources

        let refs = await Task { @MainActor in
            (try? store.fetchSenseReferences(entryID: savedID)) ?? []
        }.value
        senseReferences = refs

        // Compute conjugation groups if this is a verb — uses the saved entry's primary kanji or kana form.
        if let vc = verbClass,
           let form = savedDisplayData?.entry.kanjiForms.first?.text
                   ?? savedDisplayData?.entry.kanaForms.first?.text {
            conjugationGroups = VerbConjugator.conjugationGroups(for: form, verbClass: vc)
        }
    }

    // Maps ISO 639-2/B language codes to display names for common loanword source languages.
    private func languageName(for code: String) -> String {
        let map: [String: String] = [
            "eng": "English", "fre": "French", "ger": "German",
            "por": "Portuguese", "dut": "Dutch", "ita": "Italian",
            "spa": "Spanish", "rus": "Russian", "chi": "Chinese",
            "kor": "Korean", "san": "Sanskrit", "ara": "Arabic",
        ]
        return map[code] ?? code.uppercased()
    }

    // Renders a small pill-shaped metadata chip used across multiple sections.
    @ViewBuilder
    private func metadataLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
    }
}
