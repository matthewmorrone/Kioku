import SwiftUI

// Renders the segment-management screen for all current paste-area segments.
struct SegmentListView: View {
    @Environment(\.dismiss) private var dismiss
    // Injected so that save/unsave operations trigger a refresh in WordsView without duplicating storage logic.
    @EnvironmentObject var wordsStore: WordsStore
    // Re-injected on the WordDetailView sheet below so list-membership UI inside the detail screen
    // resolves correctly when presented from this sheet.
    @EnvironmentObject private var wordListsStore: WordListsStore

    let text: String
    let edges: [LatticeEdge]
    let latticeEdges: [LatticeEdge]
    let dictionaryStore: DictionaryStore?
    let sourceNoteID: UUID?
    let lemmaForSurface: (String) -> String?
    // Returns all dictionary-backed lemma candidates for a surface, ordered
    // best-first by the segmenter's scoring. Powers the "Choose lemma…"
    // context menu — when a surface has multiple plausible dictionary
    // entries (e.g. なった → なる, なう) the user gets to pick instead of
    // accepting the auto-picked top candidate. ReadView wires this to
    // `segmenter.lemmaCandidates(for:)`.
    let lemmaCandidatesForSurface: (String) -> [String]
    let onMergeLeft: (Int) -> Void
    let onMergeRight: (Int) -> Void
    let onSplit: (Int, Int) -> Void
    let onReset: () -> Void

    @State private var savedWordEntryIDs: Set<Int64> = []
    // Union of encountered-surface strings across all saved cards (with legacy
    // lemma expansion applied — see `applySavedWordState`). Per-surface star
    // state in segment rows checks membership here.
    @State var savedWordSurfaces: Set<String> = []
    @State private var savedWordSourceNoteIDsByEntryID: [Int64: Set<UUID>] = [:]
    // Maps each encountered-surface to the union of sourceNoteIDs from cards
    // that list it. With legacy expansion, a legacy "食べた" card also
    // contributes under its derived lemma key "食べる", so the lemma row
    // appears saved without a write migration.
    @State private var savedWordSourceNoteIDsBySurface: [String: Set<UUID>] = [:]
    @State var canonicalEntryIDBySurface: [String: Int64] = [:]
    @State private var includesDuplicates = false
    @State private var includesCommonParticles = false
    @State private var hydrationGeneration: Int = 0
    @State private var orderedSplitOffsetsBySourceIndex: [Int: [Int]] = [:]
    @State private var latticeBackedSplitOffsetsBySourceIndex: [Int: Set<Int>] = [:]
    @State var addAllFeedbackMessage: String?
    @State var addAllFeedbackTask: Task<Void, Never>?
    @State private var detailWord: SavedWord?
    // Sheet-presentation state for the lemma picker. `nil` means hidden; a
    // non-nil value carries the surface that triggered the picker (used as
    // the picker's title context) plus the candidates to show. The struct
    // is Identifiable so SwiftUI's `.sheet(item:)` can use its surface as
    // the diffing key.
    @State private var pickerContext: LemmaPickerContext?

    private struct LemmaPickerContext: Identifiable {
        let surface: String
        let candidates: [String]
        // The row's edge's surface — needed for the save action's lemma
        // metadata even after the picker overrides the displayed identity.
        let edgeSurface: String
        var id: String { surface }
    }
    // Read at view init time so a settings change takes effect on the next sheet presentation.
    private let commonParticles = ParticleSettings.allowed()

    // When on, this view treats the dictionary lemma (食べる) as the row's
    // identity — for display, save/star lookup, tap-to-detail, dedup, and
    // "Add All". When off, the raw surface (食べた) is identity. The toggle is
    // semantic, not cosmetic: flipping it changes what saving the row stores
    // in the Words list, and what the star reflects.
    //
    // Default true: dictionary form is the typical study target. Surface text
    // is still recoverable inside the Word Details sheet.
    //
    // Migration note: words saved while the toggle was off (stored with the
    // conjugated surface) will read as "not saved" on lemma rows for that
    // word, because the saved-by-surface lookup keys off the displayed string.
    // That's accurate — "食べた" and "食べる" are different entries in the store.
    @AppStorage("kioku.settings.segmentList.showLemmas") private var showLemmasInSegmentList: Bool = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Displays every active segment in source order.
                List {
                    ForEach(displayRows, id: \.sourceIndex) { row in
                        let index = row.sourceIndex
                        let edge = row.edge
                        // Shows segment text with a right-side star toggle and split/merge context actions.
                        // `rowIdentity` is the lemma when the toggle is on (and a lemma exists)
                        // — that string is now the row's identity for display AND every user-
                        // action (save, star lookup, tap detail, etc.). Computed once per row
                        // so display and behavior can't drift apart.
                        let rowIdentity = resolvedRowSurface(for: edge)
                        let rowLemma = lemmaForSurface(edge.surface) ?? ""
                        // Pre-compute candidates here (not inside contextMenu) so the
                        // @ViewBuilder closure stays short — too many items / nested
                        // conditionals there caused later items (Split sub-menu) to
                        // silently drop from the rendered menu. Also filtered to
                        // entries that actually conjugate, so the picker doesn't
                        // offer category-error candidates like the noun なつ
                        // (summer) for past-tense surface なった.
                        let lemmaPickerCandidates = filteredLemmaCandidates(forEdgeSurface: edge.surface)
                        HStack(spacing: 10) {
                            Text(rowIdentity)
                                .font(.headline)

                            Spacer()

                            Button {
                                // In lemma mode, rowIdentity == rowLemma, so we save surface=lemma,
                                // lemma=lemma — a clean dictionary-form entry. In surface mode,
                                // rowIdentity == edge.surface and rowLemma is the resolved
                                // dictionary form, preserving the surface-with-lemma metadata.
                                toggleSavedWord(rowIdentity, lemma: rowLemma)
                            } label: {
                                let normalizedSurface = normalizedSurfaceForFiltering(rowIdentity)
                                let isSavedForCurrentNote = isSavedForCurrentNote(normalizedSurface: normalizedSurface)
                                let isSavedForOtherNotes = isSavedForOtherNotes(normalizedSurface: normalizedSurface)
                                let isSavedElsewhere = isSavedSurface(normalizedSurface: normalizedSurface) && isSavedForOtherNotes == false
                                // Three visual states:
                                //   yellow filled ★  — saved here, or saved standalone (no note attribution)
                                //   yellow hollow ☆  — saved only in other notes (signals "seen elsewhere")
                                //   gray hollow   ☆  — not saved anywhere
                                // The shape now carries "saved for this note"; the color carries
                                // "saved anywhere." Previously the other-notes case was faded-gray
                                // filled, which read as "muted-yellow-ish" and was easy to confuse
                                // with the current-note state.
                                let isStarFilled = isSavedForCurrentNote || isSavedElsewhere
                                let isAnySaved = isStarFilled || isSavedForOtherNotes
                                let starColor: Color = isAnySaved ? .yellow : .secondary
                                Image(systemName: isStarFilled ? "star.fill" : "star")
                                    .foregroundStyle(starColor)
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                isSavedForCurrentNote(normalizedSurface: normalizedSurfaceForFiltering(rowIdentity)) ? "Unsave Word" : "Save Word"
                            )
                        }
                        .padding(.vertical, 6)
                        // Whole-row hit area: tapping the segment text opens the same Word
                        // Details view the long-press context menu's primary action does.
                        // Without this the rows are inert except for the star button and
                        // the long-press menu, which doesn't match the read view's
                        // "tap a word to see its definition" affordance.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            openWordDetail(for: rowIdentity, lemma: rowLemma)
                        }
                        .contextMenu {
                            Button {
                                openWordDetail(for: rowIdentity, lemma: rowLemma)
                            } label: {
                                Label("Word Details", systemImage: "info.circle")
                            }

                            // "Choose Lemma…" — manual override for the
                            // segmenter's auto-pick. Only shown when after POS
                            // filtering there are still ≥2 plausible
                            // candidates. Candidates were pre-computed at row
                            // scope above so this builder stays slim.
                            if lemmaPickerCandidates.count > 1 {
                                Button {
                                    pickerContext = LemmaPickerContext(
                                        surface: edge.surface,
                                        candidates: lemmaPickerCandidates,
                                        edgeSurface: edge.surface
                                    )
                                } label: {
                                    Label("Choose Lemma…", systemImage: "text.magnifyingglass")
                                }
                            }

                            if index > 0 {
                                Button {
                                    onMergeLeft(index)
                                } label: {
                                    Label("Merge Left", systemImage: "arrow.left.to.line.compact")
                                }
                            }

                            if index < edges.count - 1 {
                                Button {
                                    onMergeRight(index)
                                } label: {
                                    Label("Merge Right", systemImage: "arrow.right.to.line.compact")
                                }
                            }

                            let latticeBackedOffsets = latticeBackedSplitOffsetsBySourceIndex[index] ?? []
                            let orderedOffsets = orderedSplitOffsetsBySourceIndex[index] ?? []

                            // Single-offset short-circuit: when there's exactly one
                            // valid split point (typical for 2-char segments — only
                            // one cut position), skip the submenu and present the
                            // split as a flat one-tap Button. Anything ≥ 2 offsets
                            // keeps the submenu so the user can pick.
                            if orderedOffsets.count == 1,
                               let offset = orderedOffsets.first,
                               let preview = splitPreview(for: edge.surface, offsetUTF16: offset) {
                                Button {
                                    onSplit(index, offset)
                                } label: {
                                    Label("Split: \(preview.left) | \(preview.right)", systemImage: "scissors")
                                }
                            } else if orderedOffsets.count > 1 {
                                Menu("Split") {
                                    ForEach(orderedOffsets, id: \.self) { offset in
                                        if let preview = splitPreview(for: edge.surface, offsetUTF16: offset) {
                                            let labelPrefix = latticeBackedOffsets.contains(offset) ? "Suggested: " : "Manual: "
                                            Button("\(labelPrefix)\(preview.left) | \(preview.right)") {
                                                onSplit(index, offset)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Keeps basic screen actions available at the bottom.
                VStack(spacing: 4) {
                    HStack(spacing: 10) {
                        optionToggleButton(
                            title: "duplicates",
                            isOn: includesDuplicates,
                            accessibilityLabel: "Include Duplicates"
                        ) {
                            includesDuplicates.toggle()
                        }

                        optionToggleButton(
                            title: "particles",
                            isOn: includesCommonParticles,
                            accessibilityLabel: "Include Common Particles"
                        ) {
                            includesCommonParticles.toggle()
                        }

                        // Display lemma (食べる) vs raw surface (食べた). Persists
                        // across sheet presentations via AppStorage; default is
                        // on (lemma) since dictionary form is generally the study
                        // target, with surface still visible in word detail.
                        optionToggleButton(
                            title: "lemmas",
                            isOn: showLemmasInSegmentList,
                            accessibilityLabel: showLemmasInSegmentList ? "Show Surface Forms" : "Show Lemmas"
                        ) {
                            showLemmasInSegmentList.toggle()
                        }

                        Spacer(minLength: 0)

                        Button {
                            addAllVisibleWords()
                        } label: {
                            Text("Add All")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Add All Visible Words")
                    }

                    if let addAllFeedbackMessage {
                        Text(addAllFeedbackMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Dismisses the segment list sheet without depending on scroll-position gesture handoff.
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Back")
            }
        }
        .onAppear {
            loadSavedWordsFromStorage()
            scheduleCanonicalEntryIDHydrationForVisibleRows()
            rebuildSplitMenuCaches()
        }
        .onChange(of: edges.map(\.surface)) { _, _ in
            scheduleCanonicalEntryIDHydrationForVisibleRows()
            rebuildSplitMenuCaches()
        }
        .onChange(of: latticeEdges.map(\.start)) { _, _ in
            rebuildSplitMenuCaches()
        }
        .onChange(of: latticeEdges.map(\.end)) { _, _ in
            rebuildSplitMenuCaches()
        }
        .onChange(of: includesDuplicates) { _, _ in
            scheduleCanonicalEntryIDHydrationForVisibleRows()
        }
        .onChange(of: includesCommonParticles) { _, _ in
            scheduleCanonicalEntryIDHydrationForVisibleRows()
        }
        // Toggling the lemma/surface mode changes the row identity, so the
        // canonical-id cache (keyed by row identity) needs to repopulate for
        // the new key set — otherwise star state for lemma rows stays unset
        // until the user re-presents the sheet.
        .onChange(of: showLemmasInSegmentList) { _, _ in
            scheduleCanonicalEntryIDHydrationForVisibleRows()
        }
        .onDisappear {
            addAllFeedbackTask?.cancel()
            addAllFeedbackTask = nil
        }
        .sheet(item: $detailWord) { word in
            WordDetailView(
                word: word,
                reading: nil,
                dictionaryStore: dictionaryStore,
                segmenter: nil
            )
            .environmentObject(wordsStore)
            .environmentObject(wordListsStore)
            .presentationDetents([.large])
        }
        .sheet(item: $pickerContext) { context in
            LemmaPickerSheet(
                surface: context.surface,
                candidates: context.candidates,
                dictionaryStore: dictionaryStore,
                onChoose: { lemma, canonicalEntryID in
                    // The user picked a specific lemma — save it with the
                    // chosen canonical id directly (skipping the segmenter's
                    // auto-pick) and record the original edge surface as the
                    // encountered form so per-surface star state still
                    // distinguishes which conjugation the user clicked from.
                    toggleSavedWord(
                        canonicalEntryID: canonicalEntryID,
                        normalizedSurface: normalizedSurfaceForFiltering(context.edgeSurface),
                        normalizedLemma: lemma
                    )
                },
                onCancel: { /* no-op; dismiss happens in the sheet */ }
            )
            .presentationDetents([.medium, .large])
        }
    }

    // Resolves the canonical dictionary entry for a tapped surface and presents the word detail sheet.
    // Reuses the canonical-id cache populated for star rendering, falling back to a hydrate pass when
    // the row hasn't been resolved yet (e.g. fresh sheet, mid-scroll segment).
    private func openWordDetail(for surface: String, lemma: String) {
        let normalizedSurface = normalizedSurfaceForFiltering(surface)
        guard normalizedSurface.isEmpty == false else { return }

        if let entryID = canonicalEntryIDBySurface[normalizedSurface] {
            presentWordDetail(canonicalEntryID: entryID, surface: normalizedSurface)
            return
        }

        let normalizedLemma = normalizedSurfaceForFiltering(lemma)
        hydrateCanonicalEntryIDs(for: [(surface: normalizedSurface, lemma: normalizedLemma)]) { hydratedEntryIDs in
            if hydratedEntryIDs.isEmpty == false {
                canonicalEntryIDBySurface.merge(hydratedEntryIDs) { current, _ in current }
            }
            guard let entryID = hydratedEntryIDs[normalizedSurface] else { return }
            presentWordDetail(canonicalEntryID: entryID, surface: normalizedSurface)
        }
    }

    // Picks the existing SavedWord for an entry id when present so list memberships and personal
    // notes show through; otherwise builds a transient SavedWord that drives the detail screen
    // without persisting anything.
    private func presentWordDetail(canonicalEntryID: Int64, surface: String) {
        if let existing = wordsStore.words.first(where: { $0.canonicalEntryID == canonicalEntryID }) {
            detailWord = existing
        } else {
            detailWord = SavedWord(canonicalEntryID: canonicalEntryID, surface: surface)
        }
    }

    // Builds valid UTF-16 split offsets for a segment by iterating source-text character boundaries.
    private func splitOffsets(for edge: LatticeEdge) -> [Int] {
        guard edge.start < edge.end else {
            return []
        }

        var offsets: [Int] = []
        var cursor = edge.start
        var utf16Offset = 0

        while cursor < edge.end {
            let nextIndex = text.index(after: cursor)
            utf16Offset += text[cursor..<nextIndex].utf16.count
            if nextIndex < edge.end {
                offsets.append(utf16Offset)
            }
            cursor = nextIndex
        }

        return offsets
    }

    // Identifies indices that are both a lattice start and end so split options can prefer graph-supported boundaries.
    private func latticeBoundaryIndices() -> Set<String.Index> {
        var latticeStarts = Set<String.Index>()
        var latticeEnds = Set<String.Index>()

        for latticeEdge in latticeEdges {
            latticeStarts.insert(latticeEdge.start)
            latticeEnds.insert(latticeEdge.end)
        }

        return latticeStarts.intersection(latticeEnds)
    }

    // Collects split offsets that align to lattice-supported boundaries inside the selected segment span.
    private func latticeBackedSplitOffsetSet(for edge: LatticeEdge, boundaryIndices: Set<String.Index>) -> Set<Int> {
        guard edge.start < edge.end else {
            return []
        }

        var supportedOffsets = Set<Int>()
        var cursor = edge.start
        var utf16Offset = 0

        while cursor < edge.end {
            let nextIndex = text.index(after: cursor)
            utf16Offset += text[cursor..<nextIndex].utf16.count

                if nextIndex > edge.start,
                    nextIndex < edge.end,
                    boundaryIndices.contains(nextIndex) {
                supportedOffsets.insert(utf16Offset)
            }

            cursor = nextIndex
        }

        return supportedOffsets
    }

    // Rebuilds split-menu caches to keep row rendering light even for large segment lists.
    private func rebuildSplitMenuCaches() {
        let boundaryIndices = latticeBoundaryIndices()
        var orderedOffsetsByIndex: [Int: [Int]] = [:]
        var latticeBackedOffsetsByIndex: [Int: Set<Int>] = [:]

        orderedOffsetsByIndex.reserveCapacity(edges.count)
        latticeBackedOffsetsByIndex.reserveCapacity(edges.count)

        for (sourceIndex, edge) in edges.enumerated() {
            let latticeBackedOffsets = latticeBackedSplitOffsetSet(for: edge, boundaryIndices: boundaryIndices)
            let availableOffsets = splitOffsets(for: edge)
            let orderedOffsets = availableOffsets.sorted { lhs, rhs in
                let lhsIsLatticeBacked = latticeBackedOffsets.contains(lhs)
                let rhsIsLatticeBacked = latticeBackedOffsets.contains(rhs)
                if lhsIsLatticeBacked != rhsIsLatticeBacked {
                    return lhsIsLatticeBacked
                }

                return lhs < rhs
            }

            orderedOffsetsByIndex[sourceIndex] = orderedOffsets
            latticeBackedOffsetsByIndex[sourceIndex] = latticeBackedOffsets
        }

        orderedSplitOffsetsBySourceIndex = orderedOffsetsByIndex
        latticeBackedSplitOffsetsBySourceIndex = latticeBackedOffsetsByIndex
    }

    // Excludes newline-only rows so the word list mirrors visible lexical segment editing intent.
    var displayRows: [(sourceIndex: Int, edge: LatticeEdge)] {
        var filteredRows = Array(edges.enumerated())
            .filter { _, edge in
                edge.surface.contains("\n") == false && edge.surface.contains("\r") == false
            }

        // Drop rows whose entire surface is punctuation/symbols — open and close
        // parens, brackets, kuten, quotation marks, etc. Tokenizers can emit
        // these as standalone segments when the surface text contains them, but
        // they're not vocabulary candidates and clutter the list.
        // Whitespace-only rows trim to empty and also drop here (allSatisfy on
        // an empty string is true, so they pass the `isEmpty` short-circuit).
        filteredRows = filteredRows.filter { _, edge in
            isPurePunctuationOrSymbol(edge.surface) == false
        }

        if includesCommonParticles == false {
            filteredRows = filteredRows.filter { _, edge in
                isCommonParticle(edge.surface) == false
            }
        }

        if includesDuplicates == false {
            // Dedup key uses the row's identity string (lemma in lemma mode,
            // surface otherwise) so two conjugated forms of the same verb
            // collapse into one row when the user is studying lemmas. In
            // surface mode this preserves the prior behavior (dedup by raw
            // surface).
            var seenIdentities = Set<String>()
            filteredRows = filteredRows.filter { _, edge in
                let identity = normalizedSurfaceForFiltering(resolvedRowSurface(for: edge))
                if seenIdentities.contains(identity) {
                    return false
                }

                seenIdentities.insert(identity)
                return true
            }
        }

        return filteredRows.map { offset, edge in
            (sourceIndex: offset, edge: edge)
        }
    }

    // Detects whether a segment surface is one of the common Japanese particles used for extraction filtering.
    private func isCommonParticle(_ surface: String) -> Bool {
        let normalizedSurface = normalizedSurfaceForFiltering(surface)
        return commonParticles.contains(normalizedSurface)
    }

    // True when the trimmed surface consists entirely of Unicode punctuation
    // and/or symbol characters — `(`, `)`, `「`, `」`, `、`, `。`, `!`, `?`,
    // arrows, etc. Used to hide tokenizer-emitted bracket/quote segments from
    // the extract-words list since they aren't vocabulary candidates. An empty
    // (whitespace-only) surface also returns true via `allSatisfy`'s vacuous
    // success — that's intentional, those rows weren't useful either.
    //
    // Uses `Character.isPunctuation` / `isSymbol` rather than CharacterSet so
    // multi-scalar graphemes (e.g. flag emoji punctuation in mixed text) are
    // judged as one unit rather than scalar-by-scalar.
    private func isPurePunctuationOrSymbol(_ surface: String) -> Bool {
        let trimmed = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return true }
        return trimmed.allSatisfy { $0.isPunctuation || $0.isSymbol }
    }

    // Normalizes a segment surface for stable duplicate and particle comparisons.
    func normalizedSurfaceForFiltering(_ surface: String) -> String {
        surface.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The string this row uses as its identity for save/star/tap operations
    // and dedup. With `showLemmasInSegmentList` on AND a non-empty lemma
    // available, returns the lemma; otherwise the raw edge surface.
    //
    // Every call site that previously passed `edge.surface` to lookups,
    // toggleSavedWord, openWordDetail, etc. now passes this value instead, so
    // the toggle controls behavior end-to-end. Operations that work on the
    // actual text content of the note — split previews, newline checks,
    // punctuation/particle filters — keep using `edge.surface` directly
    // because they're operating on the source string, not a vocab entry.
    // Returns the lemma candidates for `edgeSurface` filtered down to those
    // that could plausibly produce this surface — i.e. whose dictionary
    // entries have at least one verb or i-adjective sense. Only these POS
    // classes actually conjugate, so for past-tense / te-form / negative-form
    // surfaces the segmenter's mechanical deinflection emits noun candidates
    // (e.g. なつ for なった) that aren't real interpretations.
    //
    // The filter is bypassed when the segmenter's first pick equals the
    // surface itself — there's no deinflection happening so all POS classes
    // are legitimate (the user might have typed a noun like "本").
    //
    // Looked up via DictionaryStore at call time, which means each call costs
    // a few SQL lookups. Acceptable here because this only runs when the row
    // re-renders (rare) and only touches a handful of candidate strings.
    private func filteredLemmaCandidates(forEdgeSurface edgeSurface: String) -> [String] {
        let candidates = lemmaCandidatesForSurface(edgeSurface)
        guard let store = dictionaryStore else { return candidates }
        let isDictionaryFormSurface = candidates.first == edgeSurface
        if isDictionaryFormSurface { return candidates }
        return candidates.filter { lemma in
            guard let entries = try? store.lookup(surface: lemma, mode: .kanjiAndKana),
                  entries.isEmpty == false else {
                return false
            }
            return entries.contains { entry in
                entry.senses.contains { sense in
                    let bits = PartOfSpeech.bits(from: sense.pos)
                    return PartOfSpeech.isVerb(bits) || PartOfSpeech.isAdjective(bits)
                }
            }
        }
    }

    // Returns the string this row uses as its identity for save/star/tap
    // operations and dedup. With `showLemmasInSegmentList` on AND a non-empty
    // lemma available, returns the lemma; otherwise the raw edge surface.
    // The toggle controls behavior end-to-end via this single function.
    func resolvedRowSurface(for edge: LatticeEdge) -> String {
        guard showLemmasInSegmentList,
              let lemma = lemmaForSurface(edge.surface),
              lemma.isEmpty == false else {
            return edge.surface
        }
        return lemma
    }

    // Renders a compact text-only toggle button used by extraction filters in the bottom action bar.
    private func optionToggleButton(title: String, isOn: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    Capsule()
                        .fill(isOn ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    // Toggles one segment surface in the saved-word list storage.
    // `lemma` is the dictionary headword. New cards store `surface = lemma`
    // (lemma-normalized at save time), with the user-clicked surface added to
    // `encounteredSurfaces`. Existing cards have only their encountered set
    // updated — the stored surface is preserved.
    private func toggleSavedWord(_ surface: String, lemma: String = "") {
        let normalizedSurface = normalizedSurfaceForFiltering(surface)
        let normalizedLemma = normalizedSurfaceForFiltering(lemma)
        let previousSavedWordSurfaces = savedWordSurfaces
        let previousSourceNoteIDsBySurface = savedWordSourceNoteIDsBySurface

        // Optimistic UI: flip the by-surface caches before the canonical lookup
        // resolves so the star repaints immediately. Persistence happens in the
        // inner toggle once we have the canonical ID; if hydration fails we
        // restore from the snapshots captured above.
        let wasSavedForCurrentNote: Bool = {
            guard let sourceNoteID else { return savedWordSurfaces.contains(normalizedSurface) }
            return savedWordSourceNoteIDsBySurface[normalizedSurface]?.contains(sourceNoteID) ?? false
        }()

        if let sourceNoteID {
            var sourceNoteIDs = savedWordSourceNoteIDsBySurface[normalizedSurface] ?? Set<UUID>()
            if wasSavedForCurrentNote {
                sourceNoteIDs.remove(sourceNoteID)
            } else {
                sourceNoteIDs.insert(sourceNoteID)
            }

            if sourceNoteIDs.isEmpty {
                savedWordSourceNoteIDsBySurface.removeValue(forKey: normalizedSurface)
                savedWordSurfaces.remove(normalizedSurface)
            } else {
                savedWordSourceNoteIDsBySurface[normalizedSurface] = sourceNoteIDs
                savedWordSurfaces.insert(normalizedSurface)
            }
        } else if wasSavedForCurrentNote {
            savedWordSurfaces.remove(normalizedSurface)
        } else {
            savedWordSurfaces.insert(normalizedSurface)
        }

        if let canonicalEntryID = canonicalEntryIDBySurface[normalizedSurface] {
            toggleSavedWord(canonicalEntryID: canonicalEntryID, normalizedSurface: normalizedSurface, normalizedLemma: normalizedLemma)
            return
        }

        hydrateCanonicalEntryIDs(for: [(surface: normalizedSurface, lemma: normalizedLemma)]) { hydratedEntryIDs in
            guard let canonicalEntryID = hydratedEntryIDs[normalizedSurface] else {
                // Reverts optimistic UI state when no canonical entry is available for persistence.
                savedWordSurfaces = previousSavedWordSurfaces
                savedWordSourceNoteIDsBySurface = previousSourceNoteIDsBySurface
                return
            }

            canonicalEntryIDBySurface.merge(hydratedEntryIDs) { current, _ in
                current
            }
            toggleSavedWord(canonicalEntryID: canonicalEntryID, normalizedSurface: normalizedSurface, normalizedLemma: normalizedLemma)
        }
    }

    // Applies save or unsave state for one canonical dictionary entry id at the
    // surface level.
    //
    // Existing card: toggles `normalizedSurface` in `encounteredSurfaces` and
    // the active note in `sourceNoteIDs`. The card is removed only when both
    // become empty. The card's stored `surface` field is preserved — it stays
    // as whatever the first save normalized to (the lemma for new saves,
    // historical surface for legacy cards).
    //
    // New card: stored surface is the lemma when one is available (lemma
    // normalization at save time), encountered set seeded with the clicked
    // surface, note IDs seeded with the active note.
    private func toggleSavedWord(canonicalEntryID: Int64, normalizedSurface: String, normalizedLemma: String) {
        var entries = wordsStore.words
        if let existingIndex = entries.firstIndex(where: { $0.canonicalEntryID == canonicalEntryID }) {
            let existingEntry = entries[existingIndex]
            var encountered = existingEntry.encounteredSurfaces
            var noteIDs = Set(existingEntry.sourceNoteIDs)

            let surfaceWasInSet = encountered.contains(normalizedSurface)
            let noteWasAttached = sourceNoteID.map { noteIDs.contains($0) } ?? false
            // A row is "currently saved here" iff both the surface is listed
            // and the note is attached (when there's a note context). Tapping
            // the star toggles that combined state.
            let wasSavedHere: Bool = {
                guard sourceNoteID != nil else { return surfaceWasInSet }
                return surfaceWasInSet && noteWasAttached
            }()

            if wasSavedHere {
                encountered.remove(normalizedSurface)
                if let sourceNoteID, encountered.isEmpty {
                    // Last encountered surface gone → drop this note's
                    // attribution. Card disappears entirely if no other note
                    // still has it on file.
                    noteIDs.remove(sourceNoteID)
                }
            } else {
                encountered.insert(normalizedSurface)
                if let sourceNoteID {
                    noteIDs.insert(sourceNoteID)
                }
            }

            if encountered.isEmpty && noteIDs.isEmpty {
                entries.remove(at: existingIndex)
            } else {
                let orderedNoteIDs = noteIDs.sorted { $0.uuidString < $1.uuidString }
                entries[existingIndex] = SavedWord(
                    canonicalEntryID: existingEntry.canonicalEntryID,
                    surface: existingEntry.surface,
                    sourceNoteIDs: orderedNoteIDs,
                    wordListIDs: existingEntry.wordListIDs,
                    personalNote: existingEntry.personalNote,
                    savedAt: existingEntry.savedAt,
                    selectedSenseIDs: existingEntry.selectedSenseIDs,
                    selectedGlosses: existingEntry.selectedGlosses,
                    encounteredSurfaces: encountered
                )
            }
        } else {
            let noteIDs: [UUID] = sourceNoteID.map { [$0] } ?? []
            let senseIDs: [Int64]
            if let store = dictionaryStore,
               let resolved = try? store.lookupEntry(entryID: canonicalEntryID) {
                senseIDs = DefaultSenseSelection.defaultSelectedSenseIDs(for: resolved)
            } else {
                senseIDs = []
            }
            // Lemma-normalize the card's display surface at create time. The
            // user-clicked surface is captured separately in encounteredSurfaces
            // so the per-surface star check still distinguishes them later.
            let storedSurface = normalizedLemma.isEmpty ? normalizedSurface : normalizedLemma
            entries.append(
                SavedWord(
                    canonicalEntryID: canonicalEntryID,
                    surface: storedSurface,
                    sourceNoteIDs: noteIDs,
                    selectedSenseIDs: senseIDs,
                    encounteredSurfaces: [normalizedSurface]
                )
            )
        }

        wordsStore.replaceAll(with: entries)
        applySavedWordState(entries: wordsStore.words)
    }

    // Refreshes star-state caches from the in-memory WordsStore snapshot, which already mirrors
    // persistent storage. Going through WordsStore avoids a redundant UserDefaults read + JSON
    // decode + normalize on view appearance.
    private func loadSavedWordsFromStorage() {
        applySavedWordState(entries: wordsStore.words)
    }

    // Applies saved-word state used by star rendering from one canonical storage snapshot.
    //
    // Per-surface star state: yellow only if the queried surface is in some
    // card's encountered set. Legacy expansion runs in-memory here — for any
    // surface in a card's encountered set, look up its lemma via the same
    // segmenter that produces the segment-list row identity, and add the
    // lemma to the expanded set. That guarantees the map key matches what
    // the lemma-mode row queries, regardless of which kanji/kana form the
    // dictionary entry happens to list first.
    //
    // Detection rule: a stored surface different from its segmenter-derived
    // lemma means the card was saved as the conjugated form — legacy
    // behavior, or pre-normalization saves. Adding the lemma to expanded
    // encountered makes the lemma row star yellow for those cards. New
    // saves (where the surface field IS the lemma) collapse to a no-op:
    // storedSurface == lemmaForSurface(storedSurface), nothing added.
    func applySavedWordState(entries: [SavedWord]) {
        savedWordEntryIDs = Set(entries.map(\.canonicalEntryID))

        var sourceNoteIDsByEntryID: [Int64: Set<UUID>] = [:]
        var sourceNoteIDsBySurface: [String: Set<UUID>] = [:]
        var unionEncountered = Set<String>()

        for entry in entries {
            let entryNoteIDs = Set(entry.sourceNoteIDs)
            sourceNoteIDsByEntryID[entry.canonicalEntryID] = entryNoteIDs

            // Decoded encountered set (with the decoder's `?? Set([surface])`
            // fallback already applied for legacy cards). We never auto-add
            // storedSurface here — for new surface-mode saves, storedSurface
            // is the lemma, and adding it would incorrectly star the lemma
            // row when the user only clicked the surface.
            var expandedEncountered = entry.encounteredSurfaces
                .map { normalizedSurfaceForFiltering($0) }
                .filter { $0.isEmpty == false }
                .reduce(into: Set<String>()) { $0.insert($1) }

            // Legacy detector at the CARD level: a card whose stored surface
            // doesn't match its own derived lemma was saved before the
            // lemma-normalization changes — its `surface` field still holds
            // the original conjugated form. Add the lemma to expansion so
            // the lemma row stars yellow for these cards. New cards have
            // storedSurface == lemmaForSurface(storedSurface) (because the
            // toggle code now writes lemma-normalized storedSurface), so
            // this check is a no-op for them — surface-mode saves keep
            // their per-surface star isolation.
            let storedSurface = normalizedSurfaceForFiltering(entry.surface)
            let storedSurfaceLemma = (lemmaForSurface(storedSurface) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if storedSurface.isEmpty == false,
               storedSurfaceLemma.isEmpty == false,
               storedSurface != storedSurfaceLemma {
                // Make sure the stored surface itself is queryable as well —
                // its decoder fallback usually already put it in the set,
                // but be defensive in case the persisted set was empty.
                expandedEncountered.insert(storedSurface)
                expandedEncountered.insert(storedSurfaceLemma)
            }

            for surface in expandedEncountered {
                unionEncountered.insert(surface)
                let merged = sourceNoteIDsBySurface[surface, default: Set<UUID>()].union(entryNoteIDs)
                sourceNoteIDsBySurface[surface] = merged
            }
        }

        savedWordSurfaces = unionEncountered
        savedWordSourceNoteIDsByEntryID = sourceNoteIDsByEntryID
        savedWordSourceNoteIDsBySurface = sourceNoteIDsBySurface
    }

    // Per-surface "saved anywhere" check. Previously this fell back to a
    // canonical-id match — that fallback was the source of the surface/lemma
    // aliasing bug (saving 食べた made the 食べる row appear saved too). Now
    // star state queries only the encountered-surface map. Legacy cards still
    // light up correctly because `applySavedWordState` expands them with the
    // derived lemma at refresh time.
    private func isSavedSurface(normalizedSurface: String) -> Bool {
        savedWordSurfaces.contains(normalizedSurface)
    }

    // True when the queried surface is saved AND attributed to the active note.
    private func isSavedForCurrentNote(normalizedSurface: String) -> Bool {
        guard let sourceNoteID else {
            return isSavedSurface(normalizedSurface: normalizedSurface)
        }
        guard let sourceNoteIDs = savedWordSourceNoteIDsBySurface[normalizedSurface] else {
            return false
        }
        return sourceNoteIDs.contains(sourceNoteID)
    }

    // True when the surface is saved but its attributions don't include the
    // active note — the "saved elsewhere" / yellow-hollow visual state.
    private func isSavedForOtherNotes(normalizedSurface: String) -> Bool {
        guard let sourceNoteID else {
            return false
        }
        guard let sourceNoteIDs = savedWordSourceNoteIDsBySurface[normalizedSurface] else {
            return false
        }
        return sourceNoteIDs.isEmpty == false && sourceNoteIDs.contains(sourceNoteID) == false
    }

    // Schedules canonical-id hydration for visible rows so lookups never block sheet presentation.
    private func scheduleCanonicalEntryIDHydrationForVisibleRows() {
        var seenSurfaces = Set<String>()
        var pairs: [(surface: String, lemma: String)] = []

        for row in displayRows {
            // "Add All" stores each visible row using the row's identity
            // (lemma in lemma mode, surface otherwise) as the saved surface.
            // This matches what the user sees: tapping "Add All" with lemmas
            // on saves the lemma list; with lemmas off saves the conjugated
            // surfaces. lemma metadata stays the dictionary form either way.
            let surface = normalizedSurfaceForFiltering(resolvedRowSurface(for: row.edge))
            guard surface.isEmpty == false,
                  canonicalEntryIDBySurface[surface] == nil,
                  seenSurfaces.contains(surface) == false else { continue }
            seenSurfaces.insert(surface)
            pairs.append((surface: surface, lemma: normalizedSurfaceForFiltering(lemmaForSurface(row.edge.surface) ?? "")))
        }

        guard pairs.isEmpty == false else { return }

        hydrationGeneration += 1
        let targetGeneration = hydrationGeneration

        hydrateCanonicalEntryIDs(for: pairs) { hydratedEntryIDs in
            guard targetGeneration == hydrationGeneration else { return }
            canonicalEntryIDBySurface.merge(hydratedEntryIDs) { current, _ in current }
        }
    }

    // Resolves canonical dictionary ids in the background and returns a surface-keyed map of successful matches.
    // For each pair, tries the surface form first and falls back to the lemma so conjugated forms resolve correctly.
    // The completion handler is always invoked on the main thread (the early-return path runs synchronously on the
    // caller's main-actor context, the async path hops back via DispatchQueue.main.async). Callers may therefore
    // mutate @State and other MainActor-isolated view state directly inside `onComplete`.
    func hydrateCanonicalEntryIDs(
        for pairs: [(surface: String, lemma: String)],
        onComplete: @escaping ([String: Int64]) -> Void
    ) {
        guard pairs.isEmpty == false, let dictionaryStore else {
            onComplete([:])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var resolvedEntryIDs: [String: Int64] = [:]
            resolvedEntryIDs.reserveCapacity(pairs.count)

            // Hashtable hits over the preloaded canonical-id map — no SQL round-trips. The
            // previous batch + per-surface fallback path used to dominate Add All latency.
            let surfaceList = pairs.compactMap { $0.surface.isEmpty ? nil : $0.surface }
            resolvedEntryIDs = dictionaryStore.lookupFirstEntryIDs(surfaces: surfaceList)

            // Resolve any surface that didn't match by trying its lemma (dictionary headword).
            // Conjugated forms like 食べた → 食べる need this fallback; map lookup keeps it cheap.
            let unresolvedLemmas = pairs.compactMap { pair -> String? in
                guard pair.lemma.isEmpty == false,
                      pair.lemma != pair.surface,
                      resolvedEntryIDs[pair.surface] == nil else { return nil }
                return pair.lemma
            }
            if unresolvedLemmas.isEmpty == false {
                let lemmaResults = dictionaryStore.lookupFirstEntryIDs(surfaces: unresolvedLemmas)
                for pair in pairs where resolvedEntryIDs[pair.surface] == nil {
                    if let entryID = lemmaResults[pair.lemma] {
                        resolvedEntryIDs[pair.surface] = entryID
                    }
                }
            }

            DispatchQueue.main.async {
                onComplete(resolvedEntryIDs)
            }
        }
    }

    // Generates preview text for a proposed split boundary.
    private func splitPreview(for surface: String, offsetUTF16: Int) -> (left: String, right: String)? {
        let totalLength = surface.utf16.count
        guard offsetUTF16 > 0, offsetUTF16 < totalLength else {
            return nil
        }

        let splitIndex = String.Index(utf16Offset: offsetUTF16, in: surface)
        let left = String(surface[..<splitIndex])
        let right = String(surface[splitIndex...])
        guard left.isEmpty == false, right.isEmpty == false else {
            return nil
        }

        return (left: left, right: right)
    }
}
