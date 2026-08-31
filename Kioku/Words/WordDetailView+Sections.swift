import SwiftUI

// The List content inside WordDetailView's body, split out of the main file to keep it under
// the line-count guardrail. `body` still owns the List/ScrollViewReader wrapper and its sheet
// modifiers; these two computed properties are just its section content, in the same order they
// used to appear inline. Split into two halves (definition-adjacent vs. everything else) rather
// than one per section so this doesn't turn into a dozen tiny files for one screen.
extension WordDetailView {
    // Definition, sublattice Paths, and Forms — the sections most directly about "what does this
    // word mean and how does it inflect," ahead of the more peripheral metadata in
    // wordDetailMetadataSections below.
    @ViewBuilder
    var wordDetailDefinitionSections: some View {
        // Single Definition section with all matching entries sorted most- to least-common.
        // Each entry's senses are preceded by an entry label + frequency tier. Non-saved
        // entries that have no everyday kanji AND whose senses are all `uk` are dropped
        // — these are kana-natural homonyms whose archive-only kanji forms add noise
        // without helping the learner. The user's saved entry is always kept so they
        // can manage selection on it.
        let savedEntryID = activeEntryID
        // When the reading switcher is active (a heteronym like 抱く / 様), the arrows own
        // navigation between readings, so the Definition shows only the active reading's
        // entry — otherwise every reading's senses stack and switching merely scrolls
        // between them instead of swapping the meaning in place.
        let readingSwitcherActive = switchableReadings.count > 1
        let filteredData = allDisplayData.filter { data in
            if readingSwitcherActive { return data.entry.entryId == savedEntryID }
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
                            // Frequency tier is intentionally NOT shown per card — it's a
                            // surface-level statistic surfaced once in the header
                            // (headerFrequencyLabel). See senseHeaderStrip.
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
        } else if hasAttemptedLoad {
            // A real lookup ran against a live dictionaryStore and came back with nothing —
            // most commonly a Word-of-the-Day notification whose entryID/surface no longer
            // resolves because the dictionary was rebuilt after the notification was baked
            // (see loadDisplayData in WordDetailView+Helpers.swift). Without this, the sheet
            // would stay silently blank below the header forever.
            ContentUnavailableView("Couldn't load this word", systemImage: "exclamationmark.triangle")
            Button("Retry") {
                Task { await loadDisplayData() }
            }
        }

        // Sublattice paths — all valid segmentation paths through the surface. Skipped
        // when the compound-verb header (base + auxiliary, with glosses) already answers
        // the same "how does this decompose" question more clearly — showing both duplicated
        // the same insight in two places, one clean (header) and one raw (this list).
        if sublatticePaths.count > 1, derivation?.compoundVerbParts == nil {
            Section("Paths — rows") {
                sublatticeDiagramRowsPerPath
            }
            Section("Paths — arcs") {
                sublatticeDiagram
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
            let keyForms = verbClass.map { VerbConjugator.keyForms(for: conjugationBase, verbClass: $0) }
                ?? VerbConjugator.adjectiveKeyForms(for: conjugationBase)
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
                        .contentShape(Rectangle())
                        .onTapGesture {
                            speak(form.surface)
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
    }

    // Everything past Forms: alternate spellings, examples, word/kanji components, related
    // words, synonyms, loanword origin, pitch accent, review stats, source notes/lists, and the
    // personal note field.
    @ViewBuilder
    var wordDetailMetadataSections: some View {
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
                    Button {
                        // Treat the tap as a lookup — record before presenting so the
                        // word lands in the History tab the same way a top-level search
                        // result would (see WordsView+Search line 205).
                        historyStore.record(canonicalEntryID: item.entry.entryId, surface: item.entry.primarySearchSurface)
                        presentedRelatedSavedWord = ephemeralSavedWord(for: item.entry)
                    } label: {
                        relatedWordRow(item.entry, relationLabel: item.relationLabel)
                    }
                    .buttonStyle(.plain)
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
                    Button {
                        historyStore.record(canonicalEntryID: entry.entryId, surface: entry.primarySearchSurface)
                        presentedRelatedSavedWord = ephemeralSavedWord(for: entry)
                    } label: {
                        relatedWordRow(entry)
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
            if let stats = wordsStore.stats[activeEntryID] {
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
                    Button {
                        ReadNoteNavigation.shared.pendingTarget = ReadNoteTarget(noteID: note.id, surface: currentSavedWord.surface)
                        dismiss()
                    } label: {
                        Label(note.title, systemImage: "doc.text")
                            .font(.subheadline)
                    }
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
}
