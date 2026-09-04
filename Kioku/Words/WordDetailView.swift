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
    // Deinflection lexicon, threaded only from the Words tab so the header reading switcher can
    // reuse the Read-tab sheet's reading gathering (ReadingVariants). Nil at call sites that don't
    // have it (Flashcards, Kanji detail) — the switcher simply doesn't appear there.
    var lexicon: Lexicon? = nil
    // Pre-computed sublattice paths from the lookup sheet. When empty, computed from the segmenter.
    var initialSublatticePaths: [[String]] = []
    // Reading data for furigana over example sentences. Defaults to empty maps so call sites
    // that don't have them (Flashcards, segment list) still compile and degrade to plain
    // example text — only the Words tab threads the real Read-tab maps through.
    var surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()
    var kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap()
    // The note this detail view was opened in the context of, if any — nil at call sites with no
    // note context (Words tab, Kanji detail, Flashcards). When set, the header star becomes
    // note-aware: it shows the same filled/hollow+primary/secondary "saved here / saved
    // elsewhere / new" states Lines mode's row star uses, and toggling attaches/detaches this
    // note instead of only ever acting on the word globally.
    var noteID: UUID? = nil

    // Provides per-word review statistics keyed by canonicalEntryID.
    // Non-private (like wordsStore) so the WordDetailView+Helpers extension can read it.
    // Provides the list of all user-created word lists so membership can be displayed.
    // Not private: also read by wordDetailMetadataSections's Saved section.
    @EnvironmentObject var wordListsStore: WordListsStore
    // Provides note titles for resolving sourceNoteIDs to human-readable labels.
    // Not private: read by wordDetailMetadataSections (WordDetailView+Sections.swift) for the
    // Saved section's source notes / list membership.
    @EnvironmentObject var notesStore: NotesStore
    @EnvironmentObject var wordsStore: WordsStore
    // Records lookups so the Related Words / Synonyms tap path matches every other lookup
    // entry point (search results, browse, WOTD deep link) which already record on tap.
    @EnvironmentObject var historyStore: HistoryStore
    // Dismisses this sheet when a source-note name in "Saved" is tapped, so the Read-tab jump
    // (routed through ReadNoteNavigation) is actually visible instead of sitting behind this sheet.
    // Not private: wordDetailMetadataSections calls this from the "Saved" section's note-tap action.
    @Environment(\.dismiss) var dismiss

    // All entries matching the saved surface; saved entry is first.
    @State var allDisplayData: [WordDisplayData] = []
    // True once loadDisplayData has completed a real attempt against a live dictionaryStore
    // (not just bailed early because the store was still nil). Distinguishes "still loading" —
    // where the content sections should stay silent and let the .task retry — from "loaded and
    // genuinely came back empty," where the user needs a visible way out instead of staring at a
    // permanently blank sheet (see the Word-of-the-Day stale-entryID case in WordDetailView+Helpers).
    @State var hasAttemptedLoad = false
    // Readings sharing this word's kanji spelling — both cross-entry heteronyms (抱く → いだく/だく/
    // うだく, distinct entries) and within-entry kana variants (涙 → なみだ/なだ, one entry), each tied
    // to its entry. Populated by loadDisplayData; drives the header reading switcher, which dedupes by
    // reading STRING (like the Read-tab lookup sheet). See WordDetailView+ReadingSwitcher.
    @State var readingVariants: [ReadingVariants.Variant] = []
    // Not private: read/written by wordDetailMetadataSections's Note section.
    @State var personalNoteText: String = ""
    // Not private: read/written by wordDetailMetadataSections's Examples section.
    @State var sentencesExpanded: Bool = false
    // Not private: read/written by wordDetailDefinitionSections's Definition section.
    // Caps senses shown per entry — light verbs like する carry dozens of senses that would
    // otherwise push every other section off the initial screen.
    @State var definitionsExpanded: Bool = false
    // Not private: read/written by wordDetailMetadataSections's Related Words section.
    @State var relatedExpanded: Bool = false
    // Not private: read/written by wordDetailMetadataSections's Kanji section.
    @State var presentedKanjiInfo: KanjiInfo? = nil
    // Tapping a row in Related Words / Synonyms opens a nested WordDetailView for that entry.
    // We build an ephemeral SavedWord (not persisted) so the existing screen — which is
    // SavedWord-shaped — can present a related DictionaryEntry without forking a parallel
    // read-only viewer. iOS stacks sheets, so the user can drill in and back out.
    // Not private: written by wordDetailMetadataSections's Related Words / Synonyms sections.
    @State var presentedRelatedSavedWord: SavedWord? = nil
    @State var wordComponents: [(surface: String, gloss: String?)] = []
    // Derivation result shown in place of the plain POS line when the saved word is a
    // recognized derived form. When the result carries `morphemes` (currently only ～がり屋)
    // the header renders a chip strip; otherwise it falls back to the single-sentence
    // `summary`. Computed in loadDisplayData; nil for non-derived words. See DerivationAnalyzer.
    @State var derivation: DerivationAnalyzer.Result? = nil
    @State var kanjiInfos: [KanjiInfo] = []
    @State var relatedEntries: [DictionaryEntry] = []
    @State var loanwordSources: [LoanwordSource] = []
    @State var senseReferences: [SenseReference] = []
    // Synonyms resolved from the saved entry's JMdict xref cross-references, shown as their own
    // section beneath the structural/kanji-family related words. See loadDisplayData.
    @State var synonymEntries: [DictionaryEntry] = []
    // Not private: written by wordDetailDefinitionSections's Forms section.
    @State var showingConjugations: Bool = false
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
    // The live saved entry for activeEntryID, if any — single lookup backing both note-aware
    // predicates below so they can't disagree with each other or with `isSaved`.
    private var activeSavedEntry: SavedWord? {
        wordsStore.words.first { $0.canonicalEntryID == activeEntryID }
    }
    // Filled-star state: attributed to noteID, or saved with no note attribution at all — mirrors
    // ComputedSavedWordState.isStarFilled (SegmentListView+SavedWords.swift) so a word reads the
    // same way whether its star lives in the segment list or in this detail view. With no noteID
    // in scope, this collapses to plain "is it saved at all," matching today's behavior.
    private var isSavedForCurrentNoteOrStandalone: Bool {
        guard let entry = activeSavedEntry else { return false }
        guard let noteID else { return true }
        return entry.sourceNoteIDs.contains(noteID) || entry.sourceNoteIDs.isEmpty
    }
    // Hollow-star-but-known state: saved, but only under some OTHER note — the "saved elsewhere"
    // signal. Always false when there's no noteID in scope (nothing to be "elsewhere" relative to).
    private var isSavedOnlyElsewhere: Bool {
        guard let entry = activeSavedEntry, let noteID else { return false }
        return entry.sourceNoteIDs.isEmpty == false && entry.sourceNoteIDs.contains(noteID) == false
    }
    // The reading the header shows after the switcher flips to a WITHIN-entry reading (涙 なみだ ↔ なだ
    // are one entry, so repointedEntryID can't express the flip). Nil until switched; then it is the
    // authoritative displayed reading. Cross-entry (heteronym) flips also set it. See WordDetailView+ReadingSwitcher.
    @State var displayedReading: String? = nil
    // The reading currently active — the switcher override once flipped, then any reading persisted
    // by an earlier flip (so reopening the view resumes cycling from where the user left off rather
    // than from the entry's default), else the opened reading. Deliberately does NOT consult
    // switchableReadings (which reads this) so there is no recursion.
    var activeReading: String? { displayedReading ?? savedChosenReading ?? reading }
    // Set by a homonym re-point tap so the List scrolls the now-saved card into view once the
    // async reload settles (the card the user tapped may sit far down the list). Cleared after
    // the scroll fires. See the .onChange(of: allDisplayData.first…) below.
    @State var scrollTargetEntryID: Int64? = nil

    // The saved entry is used for header, examples, alternates, and components.
    // Not private: read by wordDetailDefinitionSections / wordDetailMetadataSections
    // (WordDetailView+Sections.swift).
    var savedDisplayData: WordDisplayData? { allDisplayData.first }

    // Splits the kanji-family related entries into a tightly structural group (trans/intrans
    // verb counterparts and same-stem forms, counterpart first) and the looser remainder that
    // only shares the headword's primary kanji. Drives the two related-words sections below.
    // Not private: read by wordDetailMetadataSections's Related Words section.
    var relatedPartition: (structural: [StructuralRelatedEntry], others: [DictionaryEntry]) {
        guard let saved = savedDisplayData?.entry else { return ([], relatedEntries) }
        return RelatedWordsOrganizer.partition(saved: saved, related: relatedEntries)
    }

    // Distinct part-of-speech labels across the saved entry's senses, in first-seen order,
    // expanded to full English and title-cased — e.g. "Transitive Verb · Auxiliary Adjective".
    // Shown as a summary line under the headword, mirroring the reference layout.
    private var entryPOSSummary: String? {
        guard let entry = savedDisplayData?.entry else { return nil }
        // Transitivity (vt/vi) is a per-sense property, not a word-level one — unioning it
        // across every sense reads as a contradictory blanket claim for a word like する, which
        // has some transitive senses ("to place A in B") and some intransitive ones ("to cost").
        // Each sense card already shows its own transitivity correctly; this header line is only
        // meant to summarize what kind of word this is (verb class, suffix, auxiliary), so
        // transitivity is excluded here rather than flattened into something misleading.
        let excludedTags: Set<String> = ["vt", "vi"]
        var seen = Set<String>()
        var labels: [String] = []
        for sense in entry.senses {
            guard let pos = sense.pos, pos.isEmpty == false else { continue }
            for tag in pos.components(separatedBy: ",") where tag.isEmpty == false && excludedTags.contains(tag) == false {
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

    // Frequency tier ("Very Common" … "Very Rare") of the saved/active entry, shown ONCE as a
    // header badge. Frequency is a property of a written surface, not of an individual sense or
    // meaning — every source we have (wordfreq scores a string, JPDB ranks a written form) is
    // surface-keyed, and homographs that share a surface (その "that" vs 園 "garden") therefore
    // share one frequency. Rendering a tier per sense-card falsely implied each entry had its
    // own; surfacing it once here keeps the claim honest. Nil when no frequency signal exists.
    private var headerFrequencyLabel: String? {
        guard let entry = savedDisplayData?.entry else { return nil }
        return FrequencyData(jpdbRank: entry.jpdbRank, wordfreqZipf: entry.wordfreqZipf).frequencyLabel
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
    // Not private: read by wordDetailDefinitionSections's Forms section.
    var canConjugate: Bool { verbClass != nil || isIAdjective }

    // The word actually being conjugated — word.surface unless that surface is itself an
    // inflected form, in which case this is its resolved dictionary lemma. Conjugating from an
    // inflected surface directly double-inflects: 見てる (casual contraction of 見ている) fed
    // straight into the ichidan paradigm produced 見てている, a nonsense form. A plain synchronous
    // computed property (not @State set inside the async loadDisplayData) so it can never race
    // with the sheet opening before it's populated, and so the "Forms" preview and the "All
    // conjugations" sheet can never disagree about which word they're conjugating.
    // Not private: read by wordDetailDefinitionSections's Forms section.
    var conjugationBase: String {
        lexicon?.inflectionInfo(surface: word.surface)?.lemma ?? word.surface
    }

    // All conjugation groups for the "All conjugations" sheet — verb or i-adjective paradigm,
    // whichever canConjugate detected. Empty when neither applies.
    private var conjugationGroups: [ConjugationGroup] {
        if let vc = verbClass {
            return VerbConjugator.conjugationGroups(for: conjugationBase, verbClass: vc)
        } else if isIAdjective {
            return VerbConjugator.adjectiveConjugationGroups(for: conjugationBase)
        }
        return []
    }

    // Returns true when a component surface is a grammaticalized auxiliary verb in this compound context.
    // These are ichidan verbs that function as aspect/voice markers when suffixed to a masu-stem.
    // The canonical set lives on DerivationAnalyzer so the component badge and the header
    // derivation description stay in sync.
    // Not private: read by wordDetailDefinitionSections's Definition section.
    func isAuxiliaryComponent(_ surface: String) -> Bool {
        DerivationAnalyzer.auxiliaryVerbs.contains(surface)
    }

    var body: some View {
        VStack(spacing: 0) {
            let entry = savedDisplayData?.entry
            // Reading shown above the headword. Prefers the lookup-sheet reading on first open,
            // then follows the active homograph once the reading switcher flips it. See headerReading.
            let surfaceReading = headerReading(entry: entry)
            // Show lemma only when the surface is an inflected form — i.e. not present in the
            // entry's own kanji or kana forms. Mirrors the lookup sheet's lemma visibility rule.
            let surfaceIsBaseForm = entry?.kanjiForms.contains(where: { $0.text == word.surface }) == true
                || entry?.kanaForms.contains(where: { $0.text == word.surface }) == true
            // When the user's saved surface is pure kana, lemmatize to the entry's kana base
            // form — surfacing a kanji lemma (e.g. 鳴る for the inflected なりたい) attaches
            // script the user never wrote. When the surface contains kanji, prefer the first
            // everyday kanji form (skip rK/oK/iK/sK so we don't show 此処 etc).
            let lemma: String? = {
                // Compound verbs (さがしつづける = さがし-stem + auxiliary つづける) resolve to just
                // the base verb's entry (さがす), so the plain checks below would show only "さがす"
                // and silently drop the auxiliary. Show both parts when derivation() found one.
                if let parts = derivation?.compoundVerbParts {
                    return "\(parts.base) + \(parts.auxiliary)"
                }
                if surfaceIsBaseForm { return nil }
                if ScriptClassifier.containsKanji(word.surface) == false {
                    return entry?.kanaForms.first?.text
                }
                return entry?.firstEverydayKanji?.text
            }()
            // Human-readable grammatical form of the inflected surface (e.g. "potential · negative"),
            // reusing the same deinflection seam (Lexicon.inflectionInfo + InflectionFormNames) that
            // drives the Read-tab lookup header. Nil for base forms or chains with no displayable step.
            // Also nil when a compound-verb derivation is showing: describing 歩いてゆこう's raw
            // deinflection chain ("auxiliary · contraction · te-form") duplicates and reads far
            // muddier than the compoundVerbParts gloss line already rendered just below it.
            let formDescription: String? = {
                guard derivation?.compoundVerbParts == nil,
                      let lexicon,
                      let info = lexicon.inflectionInfo(surface: word.surface),
                      info.lemma != word.surface else { return nil }
                let described = InflectionFormNames.describe(info.chain)
                return described.isEmpty ? nil : described
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
                    .foregroundStyle(Color.primary)
                    .offset(x: -34)
                }
                .overlay(alignment: .trailing) {
                    let isSaved = isSavedForCurrentNoteOrStandalone
                    let isElsewhere = isSavedOnlyElsewhere
                    let learnedState = wordsStore.learnedState(for: activeEntryID)
                    Button {
                        wordsStore.toggle(
                            canonicalEntryID: activeEntryID,
                            storedSurface: word.surface,
                            encounteredSurface: word.surface,
                            sourceNoteID: noteID,
                            defaultSenseIDs: entry.map { DefaultSenseSelection.defaultSelectedSenseIDs(for: $0) } ?? []
                        )
                    } label: {
                        // Checkmark when learned, question mark when explicitly not-learned, star
                        // otherwise — the mark sits on top of saved status, so the word stays
                        // saved either way. Filled+primary / hollow+primary / hollow+secondary
                        // mirrors the segment list row star: saved here-or-standalone, saved only
                        // under another note, or never saved — see isSavedForCurrentNoteOrStandalone.
                        Image(systemName: detailLearnedIcon(state: learnedState, saved: isSaved))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle((isSaved || isElsewhere) ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 34)
                    .accessibilityLabel(isSaved ? "Unsave Word" : "Save Word")
                    .contextMenu {
                        learnedStateMenuButtons(currentState: learnedState, setState: learnedStateSetter(
                            entryID: activeEntryID,
                            wordsStore: wordsStore,
                            surface: word.surface,
                            sourceNoteID: noteID,
                            defaultSenseIDs: entry.map { DefaultSenseSelection.defaultSelectedSenseIDs(for: $0) } ?? []
                        ))
                    }
                }
                .frame(maxWidth: .infinity)
                // Reading switcher — chevrons at the row edges flank the headword (and its speaker/
                // star overlays), shown only for words with more than one reading sharing the spelling.
                .overlay(alignment: .leading) { readingSwitcherChevron(.previous) }
                .overlay(alignment: .trailing) { readingSwitcherChevron(.next) }

                // Plain-text gloss line for compound verbs, above the badge row — e.g.
                // "to search for + continue ~ing (auxiliary)". Falls back to the bare lemma
                // form when a gloss wasn't resolvable so the line stays readable either way.
                if let parts = derivation?.compoundVerbParts {
                    Text("\(parts.baseGloss ?? parts.base) + \(parts.auxiliaryGloss ?? parts.auxiliary) (auxiliary)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }

                // POS summary + "View Conjugations" — a single row beneath the headword.
                // (Speaker moved up beside the headword itself.)
                HStack(spacing: 10) {
                    // Derived forms (弱さ, お酒, 食べ始める …) describe their derivation in place
                    // of the bare POS tag. ～がり屋 returns a structured morpheme list and
                    // renders as a chip strip; compound verbs get their own gloss line below
                    // instead (see compoundVerbGlossLine) rather than the summary sentence here.
                    if let morphemes = derivation?.morphemes {
                        derivationMorphemeChips(morphemes)
                    } else if derivation?.compoundVerbParts == nil, let posSummary = derivation?.summary ?? entryPOSSummary {
                        Text(posSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    // Grammatical form of the inflected surface (e.g. "potential · negative") —
                    // alongside POS/verb-type/frequency rather than its own line above, since it's
                    // the same kind of at-a-glance metadata about the word. Styled to match the
                    // compound-verb/frequency-tier badges beside it. Hidden for base forms.
                    if let formDescription {
                        Text(formDescription)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                            .fixedSize()
                    }

                    // "Compound verb" category badge — styled to match the frequency-tier badge
                    // below (outlined capsule) rather than the filled morpheme chips, since it's
                    // a type label for the whole word, not a piece of the word itself.
                    if derivation?.compoundVerbParts != nil {
                        Text("Compound verb")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                            .fixedSize()
                    }

                    // Frequency tier for the word as a whole, in the left-aligned metadata row
                    // beside the POS summary. Shown once here (not per sense card) because
                    // frequency is a surface-level statistic — see headerFrequencyLabel.
                    if let freqLabel = headerFrequencyLabel {
                        Text(freqLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                            .fixedSize()
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
                // Section content lives in WordDetailView+Sections.swift (definition/paths/forms,
                // then everything else) to keep this file under the line-count guardrail.
                wordDetailDefinitionSections
                wordDetailMetadataSections
            }
            .listStyle(.insetGrouped)
            .sheet(isPresented: $showingConjugations) {
                if canConjugate {
                    ConjugationSheetView(
                        dictionaryForm: conjugationBase,
                        groups: conjugationGroups
                    )
                    .presentationDetents([.large])
                }
            }
            .sheet(item: $presentedKanjiInfo) { info in
                KanjiDetailView(info: info, dictionaryStore: dictionaryStore)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            // Nested WordDetail for a tapped Related Words / Synonyms row. The presented
            // SavedWord is ephemeral (built via ephemeralSavedWord(for:)); save / learned
            // toggles in the nested view still flow through WordsStore against the real
            // canonicalEntryID, so persisting from inside the nested view works the same as
            // saving from a fresh open. The same environment objects ride along so the
            // nested view's review-stats / lists / notes UI lights up identically.
            .sheet(item: $presentedRelatedSavedWord) { relatedWord in
                WordDetailView(
                    word: relatedWord,
                    reading: nil,
                    dictionaryStore: dictionaryStore,
                    segmenter: segmenter,
                    lexicon: lexicon,
                    surfaceReadingData: surfaceReadingData,
                    kanjiReadingFallback: kanjiReadingFallback,
                    noteID: noteID
                )
                .environmentObject(wordsStore)
                .environmentObject(wordListsStore)
                .environmentObject(notesStore)
                .environmentObject(historyStore)
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
        // Also keyed on word.surface: loadDisplayData's compound-verb derivation (歩いてゆこう →
        // 歩く + ゆく) depends on the exact surface, not just the entry. Without this, reopening the
        // same entry with a different surface (e.g. its plain lemma, then later an inflected compound)
        // reused the first presentation's stale `derivation` instead of recomputing, since the task id
        // hadn't changed.
        .task(id: "\(dictionaryStore != nil)|\(activeEntryID)|\(word.surface)") {
            await loadDisplayData()
        }
    }
}
