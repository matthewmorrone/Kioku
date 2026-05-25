import SwiftUI

// Renders the full-screen word detail screen shown from Words list rows.
// Major sections: title/header (furigana + lemma), definitions (all matching entries), alternate spellings, examples, components.
struct WordDetailView: View {
    let word: SavedWord
    // Reading resolved by the lookup sheet at save time — matches furigana shown there exactly.
    // Nil when opened directly from the words list (not via lookup sheet).
    let reading: String?
    let dictionaryStore: DictionaryStore?
    // Segmenter used for compound word breakdown and fallback sublattice path computation.
    let segmenter: (any TextSegmenting)?
    // Pre-computed sublattice paths from the lookup sheet. When empty, computed from the segmenter.
    var initialSublatticePaths: [[String]] = []

    // Provides per-word review statistics keyed by canonicalEntryID.
    @EnvironmentObject private var reviewStore: ReviewStore
    // Provides the list of all user-created word lists so membership can be displayed.
    @EnvironmentObject private var wordListsStore: WordListsStore
    // Provides note titles for resolving sourceNoteIDs to human-readable labels.
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject var wordsStore: WordsStore

    // All entries matching the saved surface; saved entry is first.
    @State private var allDisplayData: [WordDisplayData] = []
    @State private var personalNoteText: String = ""
    @State private var sentencesExpanded: Bool = false
    @State private var presentedKanjiInfo: KanjiInfo? = nil
    @State private var wordComponents: [(surface: String, gloss: String?)] = []
    @State private var kanjiInfos: [KanjiInfo] = []
    @State private var loanwordSources: [LoanwordSource] = []
    @State private var senseReferences: [SenseReference] = []
    @State private var showingConjugations: Bool = false
    @State private var conjugationGroups: [ConjugationGroup] = []
    @State private var sublatticePaths: [[String]] = []

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
            let surfaceReading = reading ?? inflectedReading(surface: word.surface, entry: entry)
            // Show lemma only when the surface is an inflected form — i.e. not present in the
            // entry's own kanji or kana forms. Mirrors the lookup sheet's lemma visibility rule.
            let surfaceIsBaseForm = entry?.kanjiForms.contains(where: { $0.text == word.surface }) == true
                || entry?.kanaForms.contains(where: { $0.text == word.surface }) == true
            // When the user's saved surface is pure kana, lemmatize to the entry's kana base
            // form — surfacing a kanji lemma (e.g. 鳴る for the inflected なりたい) attaches
            // script the user never wrote. When the surface contains kanji, prefer the first
            // everyday kanji form (skip rK/oK/iK/sK so we don't show 此処 etc).
            let lemma: String? = {
                if surfaceIsBaseForm { return nil }
                if ScriptClassifier.containsKanji(word.surface) == false {
                    return entry?.kanaForms.first?.text
                }
                return entry?.firstEverydayKanji?.text
            }()
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
                // Each entry's senses are preceded by an entry label + frequency tier. Non-saved
                // entries that have no everyday kanji AND whose senses are all `uk` are dropped
                // — these are kana-natural homonyms whose archive-only kanji forms add noise
                // without helping the learner. The user's saved entry is always kept so they
                // can manage selection on it.
                let savedEntryID = word.canonicalEntryID
                let filteredData = allDisplayData.filter { data in
                    if data.entry.entryId == savedEntryID { return true }
                    let kanjiHopeless = data.entry.hasNoEverydayKanji
                    let allUK = data.entry.allSensesUsuallyKana
                    return !(kanjiHopeless && allUK)
                }
                let sortedData = filteredData.sorted {
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
                            // Hierarchical layout — entry > sense > gloss.
                            // Each sense renders as its own bordered card. The header strip at
                            // the top of the card aggregates POS, frequency tier, and any misc
                            // tags (uk/arch/etc.) so all entry- and sense-level metadata sits
                            // together. Tapping the header toggles the whole-sense selection.
                            // Each gloss renders as a smaller bordered sub-card; tapping one
                            // toggles a gloss-level selection. Mutual exclusion is enforced in
                            // the toggle handlers (see toggleSenseSelection / toggleGlossSelection).
                            ForEach(sortedData, id: \.entry.entryId) { data in
                                if data.entry.senses.isEmpty == false {
                                    let freqLabel = FrequencyData(jpdbRank: data.entry.jpdbRank, wordfreqZipf: data.entry.wordfreqZipf).frequencyLabel
                                    let isSavedEntry = data.entry.entryId == word.canonicalEntryID
                                    ForEach(Array(data.entry.senses.enumerated()), id: \.offset) { idx, sense in
                                        let senseRefs = isSavedEntry
                                            ? senseReferences.filter { $0.senseOrderIndex == idx }
                                            : []
                                        let senseSentences = data.sentencesBySenseID[sense.senseID] ?? []
                                        senseCard(
                                            sense: sense,
                                            isSavedEntry: isSavedEntry,
                                            isFirstSenseInEntry: idx == 0,
                                            freqLabel: freqLabel,
                                            refs: senseRefs,
                                            sentences: senseSentences
                                        )
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                    }
                                }
                            }
                        }
                    }
                }

                // Sublattice paths — all valid segmentation paths through the surface.
                if sublatticePaths.count > 1 {
                    Section("Paths") {
                        ForEach(Array(sublatticePaths.enumerated()), id: \.offset) { _, path in
                            Text(path.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Forms section — shown for verbs only. Displays te-form / negative / past inline,
                // with an "All conjugations" row that opens ConjugationSheetView.
                if let vc = verbClass {
                    let keyForms = VerbConjugator.keyForms(for: word.surface, verbClass: vc)
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

                // Examples — only the sentences that didn't route to a specific sense.
                // Per-sense examples render inside each sense card via senseCard(sentences:).
                if let unrouted = savedDisplayData?.unroutedSentences, unrouted.isEmpty == false {
                    let shown = sentencesExpanded ? unrouted : Array(unrouted.prefix(1))
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
                        if unrouted.count > 1 {
                            Button(sentencesExpanded ? "Show fewer" : "Show \(unrouted.count - 1) more…") {
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
                // Tapping a row presents the full KanjiDetailView sheet.
                if kanjiInfos.isEmpty == false {
                    Section("Kanji") {
                        ForEach(kanjiInfos, id: \.literal) { info in
                            Button {
                                presentedKanjiInfo = info
                            } label: {
                                kanjiRowContent(info)
                            }
                            .buttonStyle(.plain)
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
                                Text(lastReviewed, format: .relative(presentation: .named))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    } else {
                        Text("Not yet reviewed")
                            .foregroundStyle(.secondary)
                    }
                }

                // Personal note — editable free-form text for mnemonics, context, etc.
                Section("Note") {
                    TextField("Add a personal note…", text: $personalNoteText, axis: .vertical)
                        .lineLimit(1...6)
                        .onChange(of: personalNoteText) {
                            let trimmed = personalNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
                            wordsStore.updatePersonalNote(
                                id: word.canonicalEntryID,
                                note: trimmed.isEmpty ? nil : trimmed
                            )
                        }
                }

                // Save date, source notes, and word list membership — always shown for context.
                Section("Saved") {
                    // Hidden for now — the save timestamp adds clutter without much value.
                    // HStack {
                    //     Text("Added")
                    //         .foregroundStyle(.secondary)
                    //     Spacer()
                    //     Text(word.savedAt, style: .date)
                    //         .foregroundStyle(.secondary)
                    // }
                    // .font(.subheadline)

                    // Source notes (songs) this word was saved from — many-to-many relationship.
                    let sourceNotes = word.sourceNoteIDs.compactMap { notesStore.note(withID: $0) }
                        .sorted { $0.title < $1.title }
                    ForEach(sourceNotes, id: \.id) { note in
                        Label(note.title, systemImage: "doc.text")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

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
                if verbClass != nil {
                    ConjugationSheetView(
                        dictionaryForm: word.surface,
                        groups: conjugationGroups,
                        onLookup: { _ in
                            // Tapping a conjugated form — lookup integration is a future task.
                            showingConjugations = false
                        }
                    )
                    .presentationDetents([.large])
                }
            }
            .sheet(item: $presentedKanjiInfo) { info in
                KanjiDetailView(info: info, dictionaryStore: dictionaryStore)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .task {
            personalNoteText = word.personalNote ?? ""
            await loadDisplayData()
        }
    }

    // Reads the live saved word from the store so the picker reflects toggled state immediately.
    // Falls back to the SavedWord the view was opened with for the brief window before the store
    // publish reaches @EnvironmentObject.
    var currentSavedWord: SavedWord {
        wordsStore.words.first { $0.canonicalEntryID == word.canonicalEntryID } ?? word
    }
    var currentSelectedSenseIDs: [Int64] { currentSavedWord.selectedSenseIDs }
    var currentSelectedGlosses: [GlossRef] { currentSavedWord.selectedGlosses }

    // Delegates to the unit-tested WordVariants helper. Surfaces both kanji and
    // kana alternates for kanji-bearing saved surfaces; returns [] for pure-kana
    // surfaces (see WordVariants for the rationale and filter rules).
    private func alternateSpellings(entry: DictionaryEntry) -> [String] {
        WordVariants.alternateSpellings(savedSurface: word.surface, entry: entry)
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

        // Fetch components and sublattice paths via segmenter when available.
        if let segmenter {
            let result = segmenter.longestMatchResult(for: surface)

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

        // Compute conjugation groups if this is a verb — conjugates against the surface the user saved
        // so kana-only saves (e.g., じゃない) don't get promoted to a canonical kanji form (じゃ無い).
        if let vc = verbClass {
            conjugationGroups = VerbConjugator.conjugationGroups(for: word.surface, verbClass: vc)
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

    // Derives the inflected reading for the surface from the entry's base forms.
    // When the surface is an inflected form (e.g. 流れた) and the entry stores the base form
    // (流れる / ながれる), the base-form reading can't project onto the inflected surface because
    // the okurigana differ (た vs る). This function finds the common prefix between the base
    // kanji form and the surface, then replaces the base suffix in the reading with the surface's suffix.
    // Returns the base reading unchanged when prefix matching fails or the entry is nil.
    private func inflectedReading(surface: String, entry: DictionaryEntry?) -> String? {
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
    private func metadataLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
    }

    // Compact tappable row content for one kanji character — extracted so the Kanji section
    // can wrap it in a Button without duplicating the layout.
    @ViewBuilder
    private func kanjiRowContent(_ info: KanjiInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
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
