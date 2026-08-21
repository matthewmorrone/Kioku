import SwiftUI

// Renders the segment-management screen for all current paste-area segments.
struct SegmentListView: View {
    // Injected so that save/unsave operations trigger a refresh in WordsView without duplicating storage logic.
    @EnvironmentObject var wordsStore: WordsStore
    // Powers the star's long-press learned-state menu, mirroring the Words tab.
    // Re-injected on the WordDetailView sheet below so list-membership UI inside the detail screen
    // resolves correctly when presented from this sheet.
    @EnvironmentObject private var wordListsStore: WordListsStore

    let text: String
    let edges: [LatticeEdge]
    let latticeEdges: [LatticeEdge]
    let dictionaryStore: DictionaryStore?
    // Threaded so the WordDetailView sheet below can show the grammatical-form caption
    // ("past — did ~ (past)") for a conjugated surface — that requires both the segmenter
    // (for lattice/lemma-candidate context) and the lexicon (for InflectionFormNames via
    // Lexicon.inflectionInfo). Neither was threaded before, so opening a word's detail from
    // this Extract Words list silently dropped the form caption that the same word shows when
    // opened via the Words tab directly.
    let segmenter: (any TextSegmenting)?
    let lexicon: Lexicon?
    let sourceNoteID: UUID?
    // Resolved the same way ReadView's Breakdown sheet does (via `currentDisplayedNote`) so the
    // Coverage page works for a note that hasn't been saved to NotesStore yet, not just
    // `sourceNoteID` lookups. Nil hides the Coverage page's content behind an empty state.
    let note: Note?
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
    // Extract-words view mode: the in-order, per-occurrence segment list ("Lines"), or the same
    // rows presented as a multi-select chip cloud ("Vocab"). Both modes read `displayRows` —
    // there's no separate extraction path for Vocab — so the duplicates/particles toggles and
    // the lemma-vs-surface identity resolution behave identically in both; Vocab is just a
    // different way of looking at the same filtered list, with multi-select instead of per-row tap.
    enum ExtractMode: String, CaseIterable, Identifiable {
        case lines = "Lines", vocab = "Vocab", coverage = "Coverage"
        var id: String { rawValue }
    }
    @State private var extractMode: ExtractMode = .lines
    // Identities the user has explicitly flipped away from their DEFAULT checked state (see
    // vocabRowCountsAsSaved) — starts empty every time the row set changes (resetVocabSelection),
    // so opening/editing Vocab mode never shows a pending change until you actually touch
    // something. A row's checked state is `vocabRowCountsAsSaved(identity) != flipped` (XOR).
    // Keyed by normalized identity rather than sourceIndex so that with duplicates shown, flipping
    // any one occurrence of a word flips every chip sharing that identity — previously this was
    // keyed by sourceIndex, so two chips for the same word (e.g. 食べる appearing twice) tracked
    // independent flip state even though saveSelectedVocab always resolved and committed by identity.
    @State private var selectedVocabIdentities: Set<String> = []

    // The ONE rule for "does this word count as saved FOR THIS NOTE SPECIFICALLY" — shared by the
    // chip's blue checked state, the Save/Remove baseline below, AND CoverageDetailView's total
    // (fed via noteWordIdentities), so all three screens' numbers agree. Strictly per-note: only
    // words actually attributed to the active note are checked. Everything else that's still
    // known — saved standalone (Words tab / dictionary lookup, no note attribution at all) or
    // attributed to a different note — is vocabRowKnownElsewhere's green state instead, never
    // blue, so unchecking a word can never silently no-op with nothing to detach (see
    // saveSelectedVocab / bug history).
    private func vocabRowCountsAsSaved(_ identity: String) -> Bool {
        isSavedForCurrentNote(normalizedSurface: identity)
    }

    // True when this identity is known — saved standalone, or attributed to some other note —
    // but not attributed to the active note: the chip's green "known elsewhere" state. Tapping
    // one attaches this note to the existing card instead of creating a duplicate:
    // addAllVisibleWords / commitAddAllVisibleWords already dedupe by canonicalEntryID, so it's
    // the same add path "brand new" (gray) rows use. It never touches the word's other
    // attributions.
    private func vocabRowKnownElsewhere(_ identity: String) -> Bool {
        isSavedForCurrentNote(normalizedSurface: identity) == false && isSavedSurface(normalizedSurface: identity)
    }

    // A row's live checked state: its default, unless the user flipped it.
    private func vocabRowIsChecked(_ row: (sourceIndex: Int, edge: LatticeEdge)) -> Bool {
        let identity = normalizedSurfaceForFiltering(resolvedRowSurface(for: row.edge))
        let defaultChecked = vocabRowCountsAsSaved(identity)
        return selectedVocabIdentities.contains(identity) ? defaultChecked == false : defaultChecked
    }

    // How many rows are checked right now vs. when this editing session started (the baseline —
    // recomputed live from wordsStore truth, which doesn't change until Save commits, so it
    // stays stable through a toggle session without needing to be snapshotted). The Save/Remove
    // button shows exactly this difference.
    private var vocabCheckedCount: Int { displayRows.filter { vocabRowIsChecked($0) }.count }
    private var vocabBaselineCheckedCount: Int {
        displayRows.filter { vocabRowCountsAsSaved(normalizedSurfaceForFiltering(resolvedRowSurface(for: $0.edge))) }.count
    }
    private var netVocabChangeCount: Int { vocabCheckedCount - vocabBaselineCheckedCount }

    // Drives the collapsed All/None toggle in the Vocab header: true once every row is checked.
    private var allVocabSelected: Bool {
        displayRows.isEmpty == false && vocabCheckedCount == displayRows.count
    }

    // The subset of displayRows whose identity is pure katakana — backs the header's Katakana
    // select-all/none pill. Computed from each row's resolved identity (lemma when one resolves,
    // else raw surface), reusing the same script classifier the dictionary/lookup UI relies on
    // rather than inventing a parallel Unicode-range check here.
    private var katakanaVocabRows: [(sourceIndex: Int, edge: LatticeEdge)] {
        displayRows.filter { ScriptClassifier.isPureKatakana(resolvedRowSurface(for: $0.edge)) }
    }

    // Drives the collapsed All/None label on the Katakana pill: true once every katakana row is
    // checked. Mirrors allVocabSelected, scoped to just the katakana subset.
    private var allKatakanaVocabSelected: Bool {
        let rows = katakanaVocabRows
        return rows.isEmpty == false && rows.allSatisfy { vocabRowIsChecked($0) }
    }

    // Clears every flip, returning the picker to its default (baseline) state. Called whenever
    // the row set changes — entering Vocab mode, editing the segmentation, toggling
    // duplicates/particles — and after a Save/Remove commits, since the freshly-persisted truth
    // becomes the new baseline.
    private func resetVocabSelectionToDefaults() {
        selectedVocabIdentities = []
    }

    // Reports each vocab chip's frame (keyed by sourceIndex) in the "vocabChipSpace" coordinate
    // space, so the paint-drag gesture below can hit-test a drag location against chip bounds
    // without every chip needing its own gesture recognizer.
    private struct VocabChipFramePreferenceKey: PreferenceKey {
        static var defaultValue: [Int: CGRect] = [:]
        // Merges frames reported by every chip into one dictionary, keyed by sourceIndex.
        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
            value.merge(nextValue()) { _, new in new }
        }
    }
    @State private var vocabChipFrames: [Int: CGRect] = [:]
    // The selection state a paint-drag applies to every chip it crosses, fixed to the opposite
    // of whatever the first-touched chip's state was — nil between drags. This is what lets one
    // continuous drag either multi-select or multi-deselect, depending on where it starts.
    @State private var vocabPaintTarget: Bool?
    // The identity under the very first touch of the current gesture, held un-toggled until a
    // second, different chip is entered (a real paint-drag) or the gesture ends untouched (a tap).
    @State private var vocabPaintFirstTouchedIdentity: String?
    // Set once a gesture is a vertical scroll attempt or a long stationary hold meant for the
    // chip's own .contextMenu — from then on this gesture is a total no-op, leaving whichever
    // other recognizer actually owns the touch (ScrollView's pan, or the long-press-for-menu) to
    // handle it uncontested instead of racing it.
    @State private var vocabPaintIsScrolling = false
    // Fires ~0.35s after a stationary first touch to flip vocabPaintIsScrolling. A real,
    // independently-scheduled timer, not a check re-run from inside onChanged — a truly
    // stationary hold may never call onChanged a second time before the finger lifts, so a
    // timestamp only checked when onChanged happens to fire again would never trigger for
    // exactly the long-press case this exists to catch. Cancelled on any real paint-drag or at
    // gesture end so a stale timer can't fire into a later, unrelated gesture.
    @State private var vocabPaintYieldTask: Task<Void, Never>?

    // Maps each rendered chip's sourceIndex to its identity, so the paint gesture (which hit-tests
    // by rendered frame, i.e. sourceIndex) can flip the identity-keyed selection set. Rebuilt from
    // displayRows on every gesture callback; the row count is small enough that this is cheaper
    // than maintaining a second cached dictionary in sync with displayRows.
    private var vocabIdentityBySourceIndex: [Int: String] {
        Dictionary(uniqueKeysWithValues: displayRows.map { ($0.sourceIndex, normalizedSurfaceForFiltering(resolvedRowSurface(for: $0.edge))) })
    }

    // Drag-to-paint-select AND plain-tap-to-toggle, unified into one gesture at
    // `minimumDistance: 0` (a Button's tap + a sibling DragGesture raced and double-toggled;
    // reverted). Attached via .simultaneousGesture so the ScrollView's pan keeps working
    // alongside it. Must NOT hijack a vertical drag (scroll attempt) or a stationary long-press
    // (the chip's own .contextMenu) — see vocabPaintIsScrolling / vocabPaintYieldTask above.
    private var vocabPaintDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("vocabChipSpace"))
            .onChanged { value in
                if vocabPaintIsScrolling { return }

                let translation = value.translation
                let verticalScrollThreshold: CGFloat = 6
                if abs(translation.height) > verticalScrollThreshold, abs(translation.height) > abs(translation.width) {
                    vocabPaintYieldTask?.cancel()
                    vocabPaintYieldTask = nil
                    vocabPaintIsScrolling = true
                    vocabPaintFirstTouchedIdentity = nil
                    vocabPaintTarget = nil
                    return
                }

                guard let sourceIndex = vocabChipFrames.first(where: { $0.value.contains(value.location) })?.key,
                      let identity = vocabIdentityBySourceIndex[sourceIndex] else { return }

                if vocabPaintTarget == nil {
                    guard let firstTouched = vocabPaintFirstTouchedIdentity else {
                        // First callback for this gesture — hold this chip un-toggled rather than
                        // flipping it immediately (don't yet know tap vs. paint-drag vs. scroll),
                        // and schedule the long-press yield (system menu fires around ~0.5s).
                        vocabPaintFirstTouchedIdentity = identity
                        vocabPaintYieldTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            guard Task.isCancelled == false else { return }
                            vocabPaintIsScrolling = true
                            vocabPaintFirstTouchedIdentity = nil
                            vocabPaintTarget = nil
                        }
                        return
                    }
                    guard identity != firstTouched else {
                        // Still on the same chip — the scheduled task above decides the yield.
                        return
                    }
                    // The finger has moved onto a second, different chip — this is a genuine
                    // paint-drag, not a tap or a scroll. Cancel the long-press yield (moot now),
                    // commit the held first chip, then fall through to paint whichever chip the
                    // finger is over this callback.
                    vocabPaintYieldTask?.cancel()
                    vocabPaintYieldTask = nil
                    vocabPaintTarget = selectedVocabIdentities.contains(firstTouched) == false
                    if vocabPaintTarget == true {
                        selectedVocabIdentities.insert(firstTouched)
                    } else {
                        selectedVocabIdentities.remove(firstTouched)
                    }
                }

                guard let target = vocabPaintTarget else { return }
                if target {
                    selectedVocabIdentities.insert(identity)
                } else {
                    selectedVocabIdentities.remove(identity)
                }
            }
            .onEnded { _ in
                vocabPaintYieldTask?.cancel()
                vocabPaintYieldTask = nil
                // The gesture stayed on one chip the whole time with no real paint-drag engaged —
                // a plain tap (or a press-and-hold that ended without becoming a scroll), so commit
                // the toggle now instead of at touch-down.
                if vocabPaintIsScrolling == false, vocabPaintTarget == nil, let identity = vocabPaintFirstTouchedIdentity {
                    if selectedVocabIdentities.contains(identity) {
                        selectedVocabIdentities.remove(identity)
                    } else {
                        selectedVocabIdentities.insert(identity)
                    }
                }
                vocabPaintTarget = nil
                vocabPaintFirstTouchedIdentity = nil
                vocabPaintIsScrolling = false
            }
    }

    // The deduped vocabulary picker: a scrollable chip cloud mirroring SubtitleImportView's, with a
    // count + All/None bulk controls above it. Each chip toggles one unique word — tapping flips
    // just that chip, dragging across several sweeps them all to the same state (vocabPaintDragGesture).
    @ViewBuilder
    private var vocabChipPicker: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text("\(vocabCheckedCount) of \(displayRows.count) already saved")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
                // Clears every flip (individual taps, paint-drags, and All/None) back to the
                // baseline saved state, without touching anything already persisted — same
                // effect as resetVocabSelectionToDefaults's other call sites (mode switches,
                // filter toggles), just user-triggered instead of automatic.
                optionToggleButton(
                    title: "Reset",
                    isOn: false,
                    accessibilityLabel: "Reset Selections"
                ) {
                    resetVocabSelectionToDefaults()
                }
                .disabled(selectedVocabIdentities.isEmpty)
                // One pill that flips between "All" and "None" (and the action it performs)
                // depending on whether everything is currently checked — instead of two separate
                // plain-text buttons, one of which was always a no-op. "All" only ever flips
                // currently-unchecked rows to checked (purely additive); "None" flips
                // currently-checked rows to unchecked, which can include real, previously-saved
                // words — the Save/Remove button's destructive styling is what surfaces that
                // before anything is actually committed.
                optionToggleButton(
                    title: allVocabSelected ? "None" : "All",
                    isOn: allVocabSelected,
                    accessibilityLabel: allVocabSelected ? "Deselect All Words" : "Select All Words"
                ) {
                    if allVocabSelected {
                        selectedVocabIdentities = Set(
                            displayRows
                                .map { normalizedSurfaceForFiltering(resolvedRowSurface(for: $0.edge)) }
                                .filter(vocabRowCountsAsSaved)
                        )
                    } else {
                        selectedVocabIdentities = Set(
                            displayRows
                                .map { normalizedSurfaceForFiltering(resolvedRowSurface(for: $0.edge)) }
                                .filter { vocabRowCountsAsSaved($0) == false }
                        )
                    }
                }
                .disabled(displayRows.isEmpty)
                // Same collapsed select-all/none pattern as the "All"/"None" pill above, scoped to
                // just the katakana subset — lets you bulk-clear the usually-noisy katakana rows
                // (loanwords, onomatopoeia) without hand-picking each chip.
                optionToggleButton(
                    title: "Katakana",
                    isOn: allKatakanaVocabSelected,
                    accessibilityLabel: allKatakanaVocabSelected ? "Deselect All Katakana Words" : "Select All Katakana Words"
                ) {
                    // Unlike the whole-list "All"/"None" pill, this is scoped to a subset, so it
                    // can't just replace selectedVocabIdentities wholesale (that would clobber any
                    // non-katakana flips already made) — each katakana identity is flipped
                    // in/out individually instead, leaving every other identity's flip untouched.
                    let wantChecked = allKatakanaVocabSelected == false
                    for identity in katakanaVocabRows.map({ normalizedSurfaceForFiltering(resolvedRowSurface(for: $0.edge)) }) {
                        // checked == (flipped != default), so flipped must equal (wantChecked != default).
                        if vocabRowCountsAsSaved(identity) != wantChecked {
                            selectedVocabIdentities.insert(identity)
                        } else {
                            selectedVocabIdentities.remove(identity)
                        }
                    }
                }
                .disabled(katakanaVocabRows.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if displayRows.isEmpty {
                Spacer()
                Text("No dictionary-backed vocabulary in this text.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    FlowLayout(spacing: 8) {
                        ForEach(displayRows, id: \.sourceIndex) { row in
                            vocabChip(row)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .coordinateSpace(name: "vocabChipSpace")
                    .onPreferenceChange(VocabChipFramePreferenceKey.self) { vocabChipFrames = $0 }
                    .simultaneousGesture(vocabPaintDragGesture)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // One vocab chip: a capsule of the row's resolved identity (lemma when one resolves, else the
    // raw surface). Wrapped in a Button purely so .contextMenu below reliably fires (see below) —
    // its action is a no-op; tap/drag both go through vocabPaintDragGesture on the container.
    @ViewBuilder
    private func vocabChip(_ row: (sourceIndex: Int, edge: LatticeEdge)) -> some View {
        let identity = resolvedRowSurface(for: row.edge)
        let normalizedIdentity = normalizedSurfaceForFiltering(identity)
        let defaultChecked = vocabRowCountsAsSaved(normalizedIdentity)
        let flipped = selectedVocabIdentities.contains(normalizedIdentity)
        let isChecked = flipped ? defaultChecked == false : defaultChecked
        let learnedState = canonicalEntryIDBySurface[normalizedIdentity].map { wordsStore.learnedState(for: $0) } ?? .unmarked

        // Three colors: blue = attributed to this note (checked); gray = not known anywhere;
        // green = known, just not for this note. Unchecking a checked row previews which of
        // gray/green it's headed for — vocabRowWouldFullyRemove tells us whether the word has
        // anything to fall back to (another note attribution, or having been an orphan before)
        // once this note's attribution is set aside; that's exactly what decides
        // detach-vs-fully-remove in saveSelectedVocab, so the color shown while editing always
        // matches what Save is about to do. A word carrying an explicit learned/not-learned mark
        // overrides this with its own color instead — a chip has no separate star glyph to carry
        // the mark the way Lines/Words rows do, so color is the only slot available for it. An
        // unmarked word (the vast majority, and every word that's never been dictionary-resolved)
        // falls through to the save-status colors above unchanged.
        let (foreground, fill, border, accessibilityState): (Color, Color, Color, String) = {
            switch learnedState {
            case .learned:
                return (.green, Color.green.opacity(0.15), Color.green.opacity(0.45), "Marked learned")
            case .notLearned:
                return (.orange, Color.orange.opacity(0.15), Color.orange.opacity(0.45), "Marked not learned")
            case .unmarked:
                if isChecked {
                    return (.accentColor, Color.accentColor.opacity(0.15), Color.accentColor.opacity(0.45), flipped ? "Will be saved for this note" : "Already saved for this note")
                } else if flipped {
                    if vocabRowWouldFullyRemove(normalizedIdentity) {
                        return (.secondary, Color(.tertiarySystemFill), .clear, "Will be fully removed")
                    }
                    return (.green, Color.green.opacity(0.15), Color.green.opacity(0.45), "Will still be saved, just not for this note")
                } else if vocabRowKnownElsewhere(normalizedIdentity) {
                    return (.green, Color.green.opacity(0.15), Color.green.opacity(0.45), "Saved elsewhere — tap to save for this note too")
                } else {
                    return (.secondary, Color(.tertiarySystemFill), .clear, "New, not yet saved")
                }
            }
        }()

        // A real Button, not plain Text, purely so .contextMenu below reliably fires — its action
        // is a no-op; every real toggle (tap, paint-drag, VoiceOver) commits via
        // selectedVocabIdentities through vocabPaintDragGesture / accessibilityAction below.
        Button {
        } label: {
            Text(identity)
                .font(.subheadline)
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(identity)
        .accessibilityValue(accessibilityState)
        // Restores what Button's default activate action would otherwise do (fire the empty
        // action above): VoiceOver's activate action doesn't route through the drag gesture,
        // since that responds to real touch/drag events.
        .accessibilityAction {
            if flipped {
                selectedVocabIdentities.remove(normalizedIdentity)
            } else {
                selectedVocabIdentities.insert(normalizedIdentity)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: VocabChipFramePreferenceKey.self,
                    value: [row.sourceIndex: proxy.frame(in: .named("vocabChipSpace"))]
                )
            }
        )
        // A vocab chip has no separate star element the way a Lines row does, so this menu
        // just carries the learned-state marks, scoped to whichever card this identity
        // resolves to.
        .contextMenu {
            if let entryID = canonicalEntryIDBySurface[normalizedIdentity] {
                learnedStateMenuButtons(currentState: learnedState, setState: learnedStateSetter(entryID: entryID, wordsStore: wordsStore, surface: identity, sourceNoteID: sourceNoteID))
            }
        }
    }

    // Every word identity (lemma when one resolves, else raw surface) Vocab mode currently
    // displays — derived directly from `displayRows` (not a separate filter pass) so this is
    // always exactly the same universe Vocab's header count is built from, including whatever
    // the duplicates/particles toggles are currently set to.
    private var noteVocabularyIdentities: Set<String> {
        Set(displayRows.map { normalizedSurfaceForFiltering(resolvedRowSurface(for: $0.edge)) })
    }

    // The subset of noteVocabularyIdentities that vocabRowCountsAsSaved marks as already-saved —
    // exactly the rule behind Vocab's "N already saved" count. Threaded into CoverageDetailView so
    // its total is that same count, computed the same way, instead of an independently-derived one.
    private var savedIdentitiesForThisNote: Set<String> {
        noteVocabularyIdentities.filter(vocabRowCountsAsSaved)
    }

    // The current note's learning-coverage breakdown, embedded directly since this sheet is
    // already scoped to one note.
    @ViewBuilder
    private var coveragePage: some View {
        if let note {
            CoverageDetailView(note: note, dictionaryStore: dictionaryStore, savedIdentitiesForThisNote: savedIdentitiesForThisNote)
        } else {
            ContentUnavailableView(
                "No note to show coverage for",
                systemImage: "chart.bar.doc.horizontal"
            )
        }
    }

    // Additions go through the exact same path Add All uses — just scoped to the flipped rows
    // instead of every visible one (the override addAllVisibleWords(rows:) was already built
    // for). That one path covers both "brand new" rows AND "known elsewhere" rows the user just
    // checked — addAllVisibleWords / commitAddAllVisibleWords already attach this note to an
    // existing card by canonicalEntryID instead of duplicating it, so there's nothing extra to do
    // here for that case. Removals split into two kinds, using the exact same
    // vocabRowWouldFullyRemove check the chip previews with, so Save always does what the chip's
    // color just promised: a row with something to fall back to (another note attribution, or
    // having been an orphan before) detaches just this note's id via WordsStore.removeNoteMembership,
    // leaving the card saved elsewhere (green); a row that's never existed independent of this
    // note has nothing to fall back to, so unchecking it is a real, full unsave via
    // WordsStore.remove instead. Both add and remove run, then the picker resets to fresh
    // defaults reflecting the just-committed truth — which becomes the new baseline for
    // netVocabChangeCount.
    private func saveSelectedVocab() {
        var addRows: [(sourceIndex: Int, edge: LatticeEdge)] = []
        var detachIdentities = Set<String>()
        var fullyRemoveIdentities = Set<String>()

        for row in displayRows {
            let identity = normalizedSurfaceForFiltering(resolvedRowSurface(for: row.edge))
            guard identity.isEmpty == false, selectedVocabIdentities.contains(identity) else { continue }
            if vocabRowCountsAsSaved(identity) {
                if vocabRowWouldFullyRemove(identity) {
                    fullyRemoveIdentities.insert(identity)
                } else {
                    detachIdentities.insert(identity)
                }
            } else {
                addRows.append(row)
            }
        }

        if addRows.isEmpty == false {
            addAllVisibleWords(rows: addRows)
        }

        if let noteID = sourceNoteID, detachIdentities.isEmpty == false {
            for identity in detachIdentities {
                if let entryID = savedCanonicalEntryID(forIdentity: identity) {
                    wordsStore.removeNoteMembership(wordID: entryID, noteID: noteID)
                }
            }
        }

        if fullyRemoveIdentities.isEmpty == false {
            let entryIDs = Set(fullyRemoveIdentities.compactMap(savedCanonicalEntryID(forIdentity:)))
            if entryIDs.isEmpty == false {
                wordsStore.remove(ids: entryIDs)
            }
        }

        if detachIdentities.isEmpty == false || fullyRemoveIdentities.isEmpty == false {
            applySavedWordState(entries: wordsStore.words)
        }

        resetVocabSelectionToDefaults()
    }

    // Resolves the canonicalEntryID of an existing SavedWord matching this identity — used to
    // resolve a "will be removed" chip's target, since both removeNoteMembership and
    // WordsStore.remove key by canonicalEntryID rather than surface text.
    private func savedCanonicalEntryID(forIdentity identity: String) -> Int64? {
        wordsStore.words.first { $0.surface == identity || $0.encounteredSurfaces.contains(identity) }?.canonicalEntryID
    }

    // Extracted out of the row's label closure — inlining this branching there previously blew
    // up the type-checker (SegmentListView's row already juggles a dozen lets per row) into a
    // multi-minute build timeout. A separate function with explicit per-statement types keeps
    // each call site a single expression for the checker to solve.
    // The checkmark/questionmark glyph is a Learned/Not-Learned mark on a SAVED word — gated on
    // isAnySaved so unsaving a learned/not-learned word visibly reverts to a hollow star instead
    // of leaving the same glyph on screen (ReviewStore's mark is keyed by canonicalEntryID and
    // outlives the SavedWord card, so learnedState alone can't tell "still saved" from "not").
    private func starIcon(isStarFilled: Bool, isAnySaved: Bool, learnedState: LearnedState) -> some View {
        let icon: String
        if isAnySaved {
            switch learnedState {
            case .learned:    icon = "checkmark"
            case .notLearned: icon = "questionmark"
            case .unmarked:   icon = isStarFilled ? "star.fill" : "star"
            }
        } else {
            icon = "star"
        }
        let starColor: Color = isAnySaved ? .primary : .secondary
        return Image(systemName: icon)
            .foregroundStyle(starColor)
            .font(.system(size: 16, weight: .semibold))
    }

    // Whether unchecking this currently-checked identity would fully unsave it rather than just
    // detach it from this note. Two ways to be safe to detach: it still has another note
    // attribution once this note's is set aside (hasAttributionBeyondCurrentNote), or it's been
    // an orphan before and can safely return to that state (SavedWord.hasBeenOrphaned). Neither
    // holding means this note is the only thing that's ever backed the word, so removing it here
    // has nothing to fall back to — a real, full unsave.
    private func vocabRowWouldFullyRemove(_ identity: String) -> Bool {
        if hasAttributionBeyondCurrentNote(normalizedSurface: identity) {
            return false
        }
        let hasBeenOrphaned = wordsStore.words.first { $0.surface == identity || $0.encounteredSurfaces.contains(identity) }?.hasBeenOrphaned ?? false
        return hasBeenOrphaned == false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Switches the row body between the in-order Lines list and the deduped Vocab
                // checklist (the subtitle-style pick-words picker). Placed above the List so it is
                // always visible, rather than in the nav bar where principal placement is unreliable.
                Picker("View mode", selection: $extractMode) {
                    ForEach(ExtractMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 20)

                if extractMode == .vocab {
                    vocabChipPicker
                } else if extractMode == .coverage {
                    coveragePage
                } else {
                // Displays every active segment in source order. Plain List: SwiftUI's
                // .contextMenu is documented to get silently promoted to the whole row inside a
                // List, which is why the star's menu and the row's own Word Details/Merge/Split
                // menu have a history of bleeding together here — under investigation.
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
                            // A sibling Button (not the star's) so its .contextMenu stays scoped to it.
                            Button {
                                // Tap opens the lookup sheet (lighter-weight UI for quick lookups).
                                // Long-press → "Word Details" still opens the full WordDetailView
                                // — preserves the tap=sheet, details=page split the user requested.
                                openLookupSheet(for: rowIdentity, lemma: rowLemma)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(rowIdentity)
                                        .font(.headline)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
                                //   primary filled   ★  — saved here, or saved standalone (no note attribution)
                                //   primary hollow   ☆  — saved only in other notes (signals "seen elsewhere")
                                //   secondary hollow ☆  — not saved anywhere
                                // The shape carries "saved for this note"; the color carries
                                // "saved anywhere." Previously the other-notes case was faded-gray
                                // filled, which read as muted-yellow-ish and was easy to confuse
                                // with the current-note state.
                                let isStarFilled = isSavedForCurrentNote || isSavedElsewhere
                                let isAnySaved = isStarFilled || isSavedForOtherNotes
                                // The mark rides on the star slot, same as the Words tab: checkmark
                                // when learned, question mark when explicitly not-learned, else the
                                // three-state star above.
                                let learnedState = canonicalEntryIDBySurface[normalizedSurface].map { wordsStore.learnedState(for: $0) } ?? .unmarked
                                starIcon(isStarFilled: isStarFilled, isAnySaved: isAnySaved, learnedState: learnedState)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                isSavedForCurrentNote(normalizedSurface: normalizedSurfaceForFiltering(rowIdentity)) ? "Unsave Word" : "Save Word"
                            )
                            .contextMenu {
                                if let entryID = canonicalEntryIDBySurface[normalizedSurfaceForFiltering(rowIdentity)] {
                                    let learnedState = wordsStore.learnedState(for: entryID)
                                    learnedStateMenuButtons(currentState: learnedState, setState: learnedStateSetter(entryID: entryID, wordsStore: wordsStore, surface: rowLemma.isEmpty ? rowIdentity : rowLemma, sourceNoteID: sourceNoteID))
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        // Kept alongside the star's own context menu above, not replacing it.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let entryID = canonicalEntryIDBySurface[normalizedSurfaceForFiltering(rowIdentity)] {
                                let learnedState = wordsStore.learnedState(for: entryID)
                                Menu {
                                    learnedStateMenuButtons(currentState: learnedState, setState: learnedStateSetter(entryID: entryID, wordsStore: wordsStore, surface: rowLemma.isEmpty ? rowIdentity : rowLemma, sourceNoteID: sourceNoteID))
                                } label: {
                                    Label("Mark…", systemImage: "ellipsis.circle")
                                }
                            }
                        }
                    }
                }
                }

                // Keeps basic screen actions available at the bottom. Coverage mode has no
                // extraction actions of its own (CoverageDetailView's cells launch study
                // sessions directly), so the bar is hidden rather than shown empty.
                if extractMode != .coverage {
                VStack(spacing: 8) {
                    // duplicates/particles now apply to Lines and Vocab alike, since both render
                    // the same `displayRows` — only the trailing action (Add All vs. Save
                    // Selected) differs by mode.
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

                        if extractMode == .vocab {
                            // Net additions minus removals, per-request: +5/-3 nets to "Save 2
                            // Words" rather than showing both counts. Negative net reads as a
                            // removal action instead, with destructive styling since it detaches
                            // word(s) from this note (though never deletes the SavedWord itself).
                            let net = netVocabChangeCount
                            Button(role: net < 0 ? .destructive : nil) {
                                saveSelectedVocab()
                            } label: {
                                Text(net < 0 ? "Remove \(-net) Words" : "Save \(net) Words")
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                            }
                            .buttonStyle(.borderedProminent)
                            .layoutPriority(1)
                            .disabled(selectedVocabIdentities.isEmpty)
                            .accessibilityLabel(net < 0 ? "Remove Selected Words From This Note" : "Save Selected Words")
                        } else {
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
            // Keep the vocab selection in sync when the user edits the segmentation while in
            // Vocab mode — displayRows (and so the chip set) just changed under it.
            if extractMode == .vocab { resetVocabSelectionToDefaults() }
        }
        .onChange(of: extractMode) { _, newMode in
            // Reset the selection lazily on first switch into Vocab mode (and on re-entry, so it
            // reflects any segmentation edits made in Lines mode).
            if newMode == .vocab { resetVocabSelectionToDefaults() }
        }
        .onChange(of: latticeEdges.map(\.start)) { _, _ in
            rebuildSplitMenuCaches()
        }
        .onChange(of: latticeEdges.map(\.end)) { _, _ in
            rebuildSplitMenuCaches()
        }
        .onChange(of: includesDuplicates) { _, _ in
            scheduleCanonicalEntryIDHydrationForVisibleRows()
            // displayRows' row set changed (occurrences collapse/expand) — resync Vocab selection.
            if extractMode == .vocab { resetVocabSelectionToDefaults() }
        }
        .onChange(of: includesCommonParticles) { _, _ in
            scheduleCanonicalEntryIDHydrationForVisibleRows()
            // displayRows' row set changed (particles appear/disappear) — resync Vocab selection.
            if extractMode == .vocab { resetVocabSelectionToDefaults() }
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
                segmenter: segmenter,
                lexicon: lexicon,
                noteID: sourceNoteID
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
