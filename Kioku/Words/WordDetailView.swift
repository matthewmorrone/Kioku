import SwiftUI
import AVFoundation

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
    // Reading data for furigana over example sentences. Defaults to empty maps so call sites
    // that don't have them (Flashcards, segment list) still compile and degrade to plain
    // example text — only the Words tab threads the real Read-tab maps through.
    var surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()
    var kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap()

    // Provides per-word review statistics keyed by canonicalEntryID.
    @EnvironmentObject private var reviewStore: ReviewStore
    // Provides the list of all user-created word lists so membership can be displayed.
    @EnvironmentObject private var wordListsStore: WordListsStore
    // Provides note titles for resolving sourceNoteIDs to human-readable labels.
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject var wordsStore: WordsStore

    // All entries matching the saved surface; saved entry is first.
    @State var allDisplayData: [WordDisplayData] = []
    @State private var personalNoteText: String = ""
    @State private var sentencesExpanded: Bool = false
    @State private var relatedExpanded: Bool = false
    @State private var presentedKanjiInfo: KanjiInfo? = nil
    @State var wordComponents: [(surface: String, gloss: String?)] = []
    // Derivation description shown in place of the plain POS line when the saved word is a
    // recognized derived form (弱さ → "Derived noun — from い-adjective 弱い + nominalizing
    // suffix さ"). Computed in loadDisplayData; nil for non-derived words. See DerivationAnalyzer.
    @State var derivationSummary: String? = nil
    @State var kanjiInfos: [KanjiInfo] = []
    @State var relatedEntries: [DictionaryEntry] = []
    @State var loanwordSources: [LoanwordSource] = []
    @State var senseReferences: [SenseReference] = []
    // Synonyms resolved from the saved entry's JMdict xref cross-references, shown as their own
    // section beneath the structural/kanji-family related words. See loadDisplayData.
    @State var synonymEntries: [DictionaryEntry] = []
    @State private var showingConjugations: Bool = false
    @State var conjugationGroups: [ConjugationGroup] = []
    @State var sublatticePaths: [[String]] = []
    // Retained for the lifetime of the view so on-demand word/sentence pronunciation
    // finishes even after the tap handler returns. Reference type → @State keeps it alive.
    @State private var speechSynthesizer = AVSpeechSynthesizer()

    // Live re-point target. Nil until the user taps a homonym definition card to switch which
    // dictionary entry this card is saved as; once set, it overrides word.canonicalEntryID as the
    // "active" entry everywhere (highlight, selection, review stats, reordering, persistence). The
    // view's `word` is a `let`, so this @State is how the switch survives within the open detail view.
    @State var repointedEntryID: Int64? = nil
    // The entry this card is currently saved as: the live re-point target if one was chosen this
    // session, otherwise the entry the view was opened with. Single source of truth for all
    // "which entry is mine" decisions across the main view and its extension files.
    var activeEntryID: Int64 { repointedEntryID ?? word.canonicalEntryID }
    // Set by a homonym re-point tap so the List scrolls the now-saved card into view once the
    // async reload settles (the card the user tapped may sit far down the list). Cleared after
    // the scroll fires. See the .onChange(of: allDisplayData.first…) below.
    @State var scrollTargetEntryID: Int64? = nil

    // The saved entry is used for header, examples, alternates, and components.
    private var savedDisplayData: WordDisplayData? { allDisplayData.first }

    // Splits the kanji-family related entries into a tightly structural group (trans/intrans
    // verb counterparts and same-stem forms, counterpart first) and the looser remainder that
    // only shares the headword's primary kanji. Drives the two related-words sections below.
    private var relatedPartition: (structural: [StructuralRelatedEntry], others: [DictionaryEntry]) {
        guard let saved = savedDisplayData?.entry else { return ([], relatedEntries) }
        return RelatedWordsOrganizer.partition(saved: saved, related: relatedEntries)
    }

    // Distinct part-of-speech labels across the saved entry's senses, in first-seen order,
    // expanded to full English and title-cased — e.g. "Transitive Verb · Auxiliary Adjective".
    // Shown as a summary line under the headword, mirroring the reference layout.
    private var entryPOSSummary: String? {
        guard let entry = savedDisplayData?.entry else { return nil }
        var seen = Set<String>()
        var labels: [String] = []
        for sense in entry.senses {
            guard let pos = sense.pos, pos.isEmpty == false else { continue }
            for tag in pos.components(separatedBy: ",") where tag.isEmpty == false {
                let label = JMdictTagExpander.expand(tag)
                if seen.insert(label).inserted { labels.append(label) }
            }
        }
        guard labels.isEmpty == false else { return nil }
        return labels.map(Self.titleCased).joined(separator: " · ")
    }

    // Title-cases a space/hyphen-delimited POS label while leaving parenthetical detail intact.
    // Non-private so relatedWordRow (WordDetailView+Helpers.swift) can reuse it.
    static func titleCased(_ label: String) -> String {
        label.split(separator: " ").map { word -> String in
            guard let first = word.first else { return String(word) }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    // Speaks arbitrary Japanese text using the system Japanese voice. Used by the header
    // speaker button and the per-example speaker buttons.
    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        speechSynthesizer.speak(utterance)
    }

    // Surfaces to highlight inside example sentences — the saved surface plus the entry's
    // kanji/kana forms, de-duplicated and longest-first so the fullest form is highlighted
    // rather than a one-character kana substring.
    var exampleHighlightSurfaces: [String] {
        var surfaces: [String] = [word.surface]
        if let entry = savedDisplayData?.entry {
            surfaces.append(contentsOf: entry.kanjiForms.map(\.text))
            surfaces.append(contentsOf: entry.kanaForms.map(\.text))
        }
        var seen = Set<String>()
        return surfaces
            .filter { $0.isEmpty == false && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
    }

    // Returns true when the saved entry is flagged as a common word in JMdict priority data.
    // Checks all kanji and kana forms for ichi1/news1/spec1 priority tags.
    private var isCommonWord: Bool {
        guard let entry = savedDisplayData?.entry else { return false }
        let priorities = (entry.kanjiForms.map(\.priority) + entry.kanaForms.map(\.priority))
            .compactMap { $0 }
        return priorities.contains { $0.contains("ichi1") || $0.contains("news1") || $0.contains("spec1") }
    }

    // Returns the verb class detected from the saved entry's POS tags, or nil for non-verbs.
    // Used to decide whether to show the Forms section. Non-private so loadDisplayData
    // (WordDetailView+Helpers.swift) can read it.
    var verbClass: VerbClass? {
        guard let entry = savedDisplayData?.entry else { return nil }
        let posTags = entry.senses.compactMap(\.pos).flatMap { $0.components(separatedBy: ",") }
        return VerbConjugator.detectVerbClass(fromJMDictPosTags: posTags)
    }

    // True when the saved entry is an i-adjective — drives the same Forms / "View Conjugations"
    // affordances as verbs, using the adjective paradigm instead of the verb one. Non-private
    // so loadDisplayData (WordDetailView+Helpers.swift) can read it.
    var isIAdjective: Bool {
        guard let entry = savedDisplayData?.entry else { return false }
        let posTags = entry.senses.compactMap(\.pos).flatMap { $0.components(separatedBy: ",") }
        return VerbConjugator.isIAdjective(fromJMDictPosTags: posTags)
    }

    // Whether this entry has a conjugation paradigm to show (verb or i-adjective).
    private var canConjugate: Bool { verbClass != nil || isIAdjective }

    // Returns true when a component surface is a grammaticalized auxiliary verb in this compound context.
    // These are ichidan verbs that function as aspect/voice markers when suffixed to a masu-stem.
    // The canonical set lives on DerivationAnalyzer so the component badge and the header
    // derivation description stay in sync.
    private func isAuxiliaryComponent(_ surface: String) -> Bool {
        DerivationAnalyzer.auxiliaryVerbs.contains(surface)
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
            VStack(spacing: 10) {
                // Headword row: the title hugs its content (.fixedSize) and centers as if it
                // were alone — the speaker rides as a trailing OVERLAY offset past the word's
                // edge, so neither it nor the star (also an overlay, below) shifts the title.
                LookupHeaderView(
                    surface: word.surface,
                    reading: surfaceReading,
                    lemma: lemma
                )
                .fixedSize()
                // Speaker rides past the title's LEADING edge (left of the word); the star rides
                // past the TRAILING edge (right of the word). Both are overlays on the fixedSize
                // title so neither shifts the centered headword.
                .overlay(alignment: .leading) {
                    Button {
                        speak(word.surface)
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .offset(x: -34)
                }
                .overlay(alignment: .trailing) {
                    let isSaved = wordsStore.words.contains { $0.canonicalEntryID == activeEntryID }
                    Button {
                        wordsStore.toggle(
                            canonicalEntryID: activeEntryID,
                            storedSurface: word.surface,
                            defaultSenseIDs: entry.map { DefaultSenseSelection.defaultSelectedSenseIDs(for: $0) } ?? []
                        )
                    } label: {
                        Image(systemName: isSaved ? "star.fill" : "star")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isSaved ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 34)
                    .accessibilityLabel(isSaved ? "Unsave Word" : "Save Word")
                }
                .frame(maxWidth: .infinity)
                // COMMON badge — outlined pill in the top-trailing corner, matching the
                // reference. Driven by the same ichi1/news1/spec1 priority heuristic.
                .overlay(alignment: .topTrailing) {
                    if isCommonWord {
                        Text("COMMON")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .overlay(
                                Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                            )
                            .padding(.trailing, 16)
                    }
                }
                // POS summary + "View Conjugations" — a single row beneath the headword.
                // (Speaker moved up beside the headword itself.)
                HStack(spacing: 10) {
                    // Derived forms (弱さ, お酒, 食べ始める …) describe their derivation in place
                    // of the bare POS tag; everything else keeps the plain expanded POS summary.
                    if let posSummary = derivationSummary ?? entryPOSSummary {
                        Text(posSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    // "View Conjugations" removed by request: it opened an empty sheet for
                    // suru-verb nouns like 記憶 (the noun itself doesn't conjugate). The Forms
                    // section below still offers conjugations for true verbs/i-adjectives.
                    // Uncomment to restore the header shortcut.
                    // if canConjugate {
                    //     Button {
                    //         showingConjugations = true
                    //     } label: {
                    //         HStack(spacing: 2) {
                    //             Text("View Conjugations")
                    //                 .font(.subheadline)
                    //             Image(systemName: "chevron.right")
                    //                 .font(.caption2)
                    //         }
                    //     }
                    //     .buttonStyle(.plain)
                    //     .foregroundStyle(Color.accentColor)
                    //     .fixedSize()
                    // }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollViewReader { proxy in
            List {
                // Single Definition section with all matching entries sorted most- to least-common.
                // Each entry's senses are preceded by an entry label + frequency tier. Non-saved
                // entries that have no everyday kanji AND whose senses are all `uk` are dropped
                // — these are kana-natural homonyms whose archive-only kanji forms add noise
                // without helping the learner. The user's saved entry is always kept so they
                // can manage selection on it.
                let savedEntryID = activeEntryID
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
                        // Prefer the word's own definition when it has one; fall back to the
                        // component decomposition only when no entry has senses. The breakdown
                        // still appears in the separate Components section regardless.
                        let hasDefinition = sortedData.contains { $0.entry.senses.isEmpty == false }
                        if wordComponents.isEmpty == false && hasDefinition == false {
                            // No definition for the whole word — show its component breakdown.
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
                                    let isSavedEntry = data.entry.entryId == activeEntryID
                                    ForEach(Array(data.entry.senses.enumerated()), id: \.offset) { idx, sense in
                                        let senseRefs = isSavedEntry
                                            ? senseReferences.filter { $0.senseOrderIndex == idx }
                                            : []
                                        let senseSentences = data.sentencesBySenseID[sense.senseID] ?? []
                                        senseCard(
                                            sense: sense,
                                            entryID: data.entry.entryId,
                                            isSavedEntry: isSavedEntry,
                                            freqLabel: freqLabel,
                                            refs: senseRefs,
                                            sentences: senseSentences
                                        )
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        // Scroll anchor so a homonym re-point can bring this card into view.
                                        .id("def-\(data.entry.entryId)-\(idx)")
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

                // Forms section — shown for verbs and i-adjectives. Displays te-form / negative /
                // past inline, with an "All conjugations" row that opens ConjugationSheetView.
                if canConjugate {
                    let keyForms = verbClass.map { VerbConjugator.keyForms(for: word.surface, verbClass: $0) }
                        ?? VerbConjugator.adjectiveKeyForms(for: word.surface)
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
                            ExampleSentenceView(
                                japanese: pair.japanese,
                                english: pair.english,
                                highlightSurfaces: exampleHighlightSurfaces,
                                segmenter: segmenter,
                                surfaceReadingData: surfaceReadingData,
                                kanjiReadingFallback: kanjiReadingFallback,
                                textSize: 17,
                                onSpeak: { speak($0) }
                            )
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

                // Related words in a single "Related Words" list. The entries a learner most
                // wants — transitive/intransitive verb counterparts and same-stem forms, each
                // tagged with its relationship — are ordered first, followed by the looser
                // kanji-family remainder that shares only the primary kanji. The combined list
                // is capped with a "Show # more…" button. Synonyms (JMdict xref "see also"
                // cross-references) stay in their own section below.
                let partition = relatedPartition
                let relatedItems: [(entry: DictionaryEntry, relationLabel: String?)] =
                    partition.structural.map { ($0.entry, RelatedWordsOrganizer.label(for: $0.relation)) }
                    + partition.others.map { ($0, nil) }

                if relatedItems.isEmpty == false {
                    let shownRelated = relatedExpanded ? relatedItems : Array(relatedItems.prefix(5))
                    Section("Related Words") {
                        ForEach(shownRelated, id: \.entry.entryId) { item in
                            relatedWordRow(item.entry, relationLabel: item.relationLabel)
                        }
                        if relatedItems.count > 5 {
                            Button(relatedExpanded ? "Show fewer" : "Show \(relatedItems.count - 5) more…") {
                                relatedExpanded.toggle()
                            }
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }

                if synonymEntries.isEmpty == false {
                    Section("Synonyms") {
                        ForEach(synonymEntries, id: \.entryId) { entry in
                            relatedWordRow(entry)
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
                    if let stats = reviewStore.stats[activeEntryID] {
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

                // Source notes (songs) this word was saved from — many-to-many relationship.
                // Sits ABOVE the personal-note section so membership context comes first.
                // Read from the live saved word (currentSavedWord) rather than the immutable `word`
                // so a re-point's carried-over notes/lists are reflected without reopening the view.
                let sourceNotes = currentSavedWord.sourceNoteIDs.compactMap { notesStore.note(withID: $0) }
                    .sorted { $0.title < $1.title }
                // Resolve list objects from IDs so the user sees human-readable labels keyed by stable UUID.
                let memberLists = wordListsStore.lists
                    .filter { currentSavedWord.wordListIDs.contains($0.id) }
                    .sorted { $0.name < $1.name }
                // Only show the "Saved" section when the word actually belongs to a source note
                // or a list — otherwise the header reads "Saved" over nothing.
                if sourceNotes.isEmpty == false || memberLists.isEmpty == false {
                    Section("Saved") {
                        ForEach(sourceNotes, id: \.id) { note in
                            Label(note.title, systemImage: "doc.text")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(memberLists, id: \.id) { list in
                            Label(list.name, systemImage: "list.bullet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Personal note — editable free-form text for mnemonics, context, etc.
                Section("Note") {
                    TextField("Add a personal note…", text: $personalNoteText, axis: .vertical)
                        .lineLimit(1...6)
                        .onChange(of: personalNoteText) {
                            let trimmed = personalNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
                            wordsStore.updatePersonalNote(
                                id: activeEntryID,
                                note: trimmed.isEmpty ? nil : trimmed
                            )
                        }
                }

            }
            .listStyle(.insetGrouped)
            .sheet(isPresented: $showingConjugations) {
                if canConjugate {
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
            // After a homonym re-point, loadDisplayData reorders the now-saved entry to the front
            // of allDisplayData. Waiting for that first-entry flip (rather than scrolling on the tap
            // itself) means the scroll fires once the reload has settled, so it lands on stable rows
            // instead of fighting the in-flight data swap. Frequency still orders the visible cards,
            // so this brings the tapped card into view wherever it sits.
            .onChange(of: allDisplayData.first?.entry.entryId) { _, firstID in
                guard let target = scrollTargetEntryID, firstID == target else { return }
                withAnimation { proxy.scrollTo("def-\(target)-0", anchor: .center) }
                scrollTargetEntryID = nil
            }
            }
        }
        .onAppear {
            personalNoteText = word.personalNote ?? ""
        }
        // Keyed on store-readiness, not just view lifetime: when this view is opened via the
        // Word of the Day deep link on a COLD LAUNCH, the dictionary SQLite is still loading and
        // dictionaryStore is nil, so loadDisplayData() bails and every content section (Definition/
        // Examples/Kanji/…) stays hidden behind the always-on shell. The store becomes non-nil once
        // it finishes loading (ReadResources re-renders the tree), and keying the task on that flip
        // re-runs the load so the content fills in. Mirrors WordsView's `.task(id: dictionaryStore != nil)`.
        // Also keyed on activeEntryID so tapping a homonym definition (which re-points the card to a
        // different entry) re-runs the load: that re-orders the saved entry to the front and refreshes
        // its sense references / loanword / conjugation data for the newly-active entry.
        .task(id: "\(dictionaryStore != nil)|\(activeEntryID)") {
            await loadDisplayData()
        }
    }
}
