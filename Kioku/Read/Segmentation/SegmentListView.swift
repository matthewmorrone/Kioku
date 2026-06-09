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
    // entries (e.g. した → した, する) the user gets to pick instead of
    // accepting the auto-picked top candidate. ReadView wires this to
    // `segmenter.lemmaCandidates(for:)`.
    let lemmaCandidatesForSurface: (String) -> [String]
    let onMergeLeft: (Int) -> Void
    let onMergeRight: (Int) -> Void
    let onSplit: (Int, Int) -> Void
    let onReset: () -> Void

    @State var savedWordEntryIDs: Set<Int64> = []
    // Union of encountered-surface strings across all saved cards (with legacy
    // lemma expansion applied — see `applySavedWordState`). Per-surface star
    // state in segment rows checks membership here.
    @State var savedWordSurfaces: Set<String> = []
    @State var savedWordSourceNoteIDsByEntryID: [Int64: Set<UUID>] = [:]
    // Maps each encountered-surface to the union of sourceNoteIDs from cards
    // that list it. With legacy expansion, a legacy "食べた" card also
    // contributes under its derived lemma key "食べる", so the lemma row
    // appears saved without a write migration.
    @State var savedWordSourceNoteIDsBySurface: [String: Set<UUID>] = [:]
    @State var canonicalEntryIDBySurface: [String: Int64] = [:]
    // Memoizes `lemmaForSurface(edge.surface)` results — populated off-main when
    // `edges` changes (see `hydrateLemmasForEdgeSurfaces`). Body row rendering,
    // `resolvedRowSurface`, and `displayRows` dedup all read through this cache,
    // falling back to a live segmenter call on miss. Empty value means "checked,
    // no lemma resolved" so the cache distinguishes miss from hit.
    @State var lemmaCacheByEdgeSurface: [String: String] = [:]
    // Cross-call memoization for `applySavedWordState`'s per-card legacy detection
    // (`lemmaForSurface(storedSurface)`). Persists across the sheet's lifetime so
    // toggling a star doesn't re-segment every previously-seen storedSurface on
    // each rebuild. Same empty-string-as-checked convention as the edge cache.
    @State var lemmaCacheByStoredSurface: [String: String] = [:]
    @State var includesDuplicates = false
    @State var includesCommonParticles = false
    @State var hydrationGeneration: Int = 0
    @State var orderedSplitOffsetsBySourceIndex: [Int: [Int]] = [:]
    @State var latticeBackedSplitOffsetsBySourceIndex: [Int: Set<Int>] = [:]
    @State var addAllFeedbackMessage: String?
    @State var addAllFeedbackTask: Task<Void, Never>?
    @State var detailWord: SavedWord?
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
    let commonParticles = ParticleSettings.allowed()

    // Row identity is unconditionally the dictionary lemma when one resolves,
    // otherwise the raw edge surface. Used for display, save/star lookup,
    // tap-to-detail, dedup, and Add All. Previously this was switchable via a
    // `lemmas` toggle in the bottom bar; the toggle was deleted because the
    // single-tap save path was already lemma-only (so the toggle's "surface
    // mode" caused divergent semantics between Add All and tap-to-save). The
    // raw conjugation the user clicked is preserved in `encounteredSurfaces`.
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
                        let rowLemma = cachedLemma(forEdgeSurface: edge.surface)
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
                            // Tap opens the lookup sheet (lighter-weight UI for quick lookups).
                            // Long-press → "Word Details" still opens the full WordDetailView
                            // — preserves the tap=sheet, details=page split the user requested.
                            openLookupSheet(for: rowIdentity, lemma: rowLemma)
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

                        Spacer(minLength: 0)

                        Button {
                            addAllVisibleWords()
                        } label: {
                            Text("Add All")
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .layoutPriority(1)
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
        // Standard iOS grabber bar at the top of the sheet. Gives the user a
        // dedicated drag handle that lets them swipe the sheet down to dismiss
        // regardless of scroll position — without this, the List's scroll
        // gesture wins from any non-top scroll offset and the only way out is
        // the back button or swiping from the very top edge.
        .presentationDragIndicator(.visible)
        .onAppear {
            loadSavedWordsFromStorage()
            hydrateLemmasForEdgeSurfaces()
            scheduleCanonicalEntryIDHydrationForVisibleRows()
            rebuildSplitMenuCaches()
        }
        .onChange(of: edges.map(\.surface)) { _, _ in
            hydrateLemmasForEdgeSurfaces()
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

    // Renders a compact text-only toggle button used by extraction filters in the bottom action bar.
    private func optionToggleButton(title: String, isOn: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ReadToggleAppearance.foreground(isOn: isOn))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    Capsule()
                        .fill(ReadToggleAppearance.background)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
