import SwiftUI

// Vocab-mode subsystem: the deduped chip-cloud picker (as opposed to the in-order Lines list),
// its paint-drag multi-select gesture, and the save/remove commit path. Split out of
// SegmentListView.swift to keep that file under the line-count guardrail — see
// SegmentListView+Hydration/Splitting/Filtering/SavedWords/AddAll.swift for the established
// per-concern split this follows. Members `body` (in the main file) or `coveragePage` calls
// directly are internal; everything used only within this file stays `private`.
extension SegmentListView {
    // Identities the user has explicitly flipped away from their DEFAULT checked state (see
    // vocabRowCountsAsSaved) — starts empty every time the row set changes (resetVocabSelection),
    // so opening/editing Vocab mode never shows a pending change until you actually touch
    // something. A row's checked state is `vocabRowCountsAsSaved(identity) != flipped` (XOR).
    // Keyed by normalized identity rather than sourceIndex so that with duplicates shown, flipping
    // any one occurrence of a word flips every chip sharing that identity — previously this was
    // keyed by sourceIndex, so two chips for the same word (e.g. 食べる appearing twice) tracked
    // independent flip state even though saveSelectedVocab always resolved and committed by identity.
    // Internal (not private): `body`, in the main file, reads `selectedVocabIdentities.isEmpty`
    // directly to gate the Save/Remove button.

    // The ONE rule for "does this word count as saved FOR THIS NOTE SPECIFICALLY" — shared by the
    // chip's blue checked state, the Save/Remove baseline below, AND CoverageDetailView's total
    // (fed via noteWordIdentities), so all three screens' numbers agree. Strictly per-note: only
    // words actually attributed to the active note are checked. Everything else that's still
    // known — saved standalone (Words tab / dictionary lookup, no note attribution at all) or
    // attributed to a different note — is vocabRowKnownElsewhere's green state instead, never
    // blue, so unchecking a word can never silently no-op with nothing to detach (see
    // saveSelectedVocab / bug history).
    fileprivate func vocabRowCountsAsSaved(_ identity: String) -> Bool {
        isSavedForCurrentNote(normalizedSurface: identity)
    }

    // True when this identity is known — saved standalone, or attributed to some other note —
    // but not attributed to the active note: the chip's green "known elsewhere" state. Tapping
    // one attaches this note to the existing card instead of creating a duplicate:
    // addAllVisibleWords / commitAddAllVisibleWords already dedupe by canonicalEntryID, so it's
    // the same add path "brand new" (gray) rows use. It never touches the word's other
    // attributions.
    fileprivate func vocabRowKnownElsewhere(_ identity: String) -> Bool {
        isSavedForCurrentNote(normalizedSurface: identity) == false && isSavedSurface(normalizedSurface: identity)
    }

    // A row's live checked state: its default, unless the user flipped it.
    fileprivate func vocabRowIsChecked(_ row: (sourceIndex: Int, edge: LatticeEdge)) -> Bool {
        let identity = normalizedSurfaceForFiltering(resolvedRowSurface(for: row.edge))
        let defaultChecked = vocabRowCountsAsSaved(identity)
        return selectedVocabIdentities.contains(identity) ? defaultChecked == false : defaultChecked
    }

    // How many rows are checked right now vs. when this editing session started (the baseline —
    // recomputed live from wordsStore truth, which doesn't change until Save commits, so it
    // stays stable through a toggle session without needing to be snapshotted). The Save/Remove
    // button shows exactly this difference.
    fileprivate var vocabCheckedCount: Int { displayRows.filter { vocabRowIsChecked($0) }.count }
    fileprivate var vocabBaselineCheckedCount: Int {
        displayRows.filter { vocabRowCountsAsSaved(normalizedSurfaceForFiltering(resolvedRowSurface(for: $0.edge))) }.count
    }
    // Internal: `body` reads this directly to label/style the Save/Remove button.
    var netVocabChangeCount: Int { vocabCheckedCount - vocabBaselineCheckedCount }

    // Drives the collapsed All/None toggle in the Vocab header: true once every row is checked.
    fileprivate var allVocabSelected: Bool {
        displayRows.isEmpty == false && vocabCheckedCount == displayRows.count
    }

    // The subset of displayRows whose identity is pure katakana — backs the header's Katakana
    // select-all/none pill. Computed from each row's resolved identity (lemma when one resolves,
    // else raw surface), reusing the same script classifier the dictionary/lookup UI relies on
    // rather than inventing a parallel Unicode-range check here.
    fileprivate var katakanaVocabRows: [(sourceIndex: Int, edge: LatticeEdge)] {
        displayRows.filter { ScriptClassifier.isPureKatakana(resolvedRowSurface(for: $0.edge)) }
    }

    // Drives the collapsed All/None label on the Katakana pill: true once every katakana row is
    // checked. Mirrors allVocabSelected, scoped to just the katakana subset.
    fileprivate var allKatakanaVocabSelected: Bool {
        let rows = katakanaVocabRows
        return rows.isEmpty == false && rows.allSatisfy { vocabRowIsChecked($0) }
    }

    // Clears every flip, returning the picker to its default (baseline) state. Called whenever
    // the row set changes — entering Vocab mode, editing the segmentation, toggling
    // duplicates/particles — and after a Save/Remove commits, since the freshly-persisted truth
    // becomes the new baseline. Internal: `body`'s onChange handlers call this directly.
    func resetVocabSelectionToDefaults() {
        selectedVocabIdentities = []
    }

    // Reports each vocab chip's frame (keyed by sourceIndex) in the "vocabChipSpace" coordinate
    // space, so the paint-drag gesture below can hit-test a drag location against chip bounds
    // without every chip needing its own gesture recognizer.
    fileprivate struct VocabChipFramePreferenceKey: PreferenceKey {
        static var defaultValue: [Int: CGRect] = [:]
        // Merges frames reported by every chip into one dictionary, keyed by sourceIndex.
        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    // Maps each rendered chip's sourceIndex to its identity, so the paint gesture (which hit-tests
    // by rendered frame, i.e. sourceIndex) can flip the identity-keyed selection set. Rebuilt from
    // displayRows on every gesture callback; the row count is small enough that this is cheaper
    // than maintaining a second cached dictionary in sync with displayRows.
    fileprivate var vocabIdentityBySourceIndex: [Int: String] {
        Dictionary(uniqueKeysWithValues: displayRows.map { ($0.sourceIndex, normalizedSurfaceForFiltering(resolvedRowSurface(for: $0.edge))) })
    }

    // Drag-to-paint-select AND plain-tap-to-toggle, unified into one gesture at
    // `minimumDistance: 0` (a Button's tap + a sibling DragGesture raced and double-toggled;
    // reverted). Attached via .simultaneousGesture so the ScrollView's pan keeps working
    // alongside it. Must NOT hijack a vertical drag (scroll attempt) or a stationary long-press
    // (the chip's own .contextMenu) — see vocabPaintIsScrolling / vocabPaintYieldTask above.
    fileprivate var vocabPaintDragGesture: some Gesture {
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
    // Internal: `body`, in the main file, switches to this view when extractMode == .vocab.
    @ViewBuilder
    var vocabChipPicker: some View {
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
    fileprivate func vocabChip(_ row: (sourceIndex: Int, edge: LatticeEdge)) -> some View {
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
    fileprivate var noteVocabularyIdentities: Set<String> {
        Set(displayRows.map { normalizedSurfaceForFiltering(resolvedRowSurface(for: $0.edge)) })
    }

    // The subset of noteVocabularyIdentities that vocabRowCountsAsSaved marks as already-saved —
    // exactly the rule behind Vocab's "N already saved" count. Threaded into CoverageDetailView so
    // its total is that same count, computed the same way, instead of an independently-derived one.
    // Internal: `coveragePage`, in the main file, reads this to build CoverageDetailView.
    var savedIdentitiesForThisNote: Set<String> {
        noteVocabularyIdentities.filter(vocabRowCountsAsSaved)
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
    // netVocabChangeCount. Internal: `body`, in the main file, calls this from the Save/Remove button.
    func saveSelectedVocab() {
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
    fileprivate func savedCanonicalEntryID(forIdentity identity: String) -> Int64? {
        wordsStore.words.first { $0.surface == identity || $0.encounteredSurfaces.contains(identity) }?.canonicalEntryID
    }

    // Whether unchecking this currently-checked identity would fully unsave it rather than just
    // detach it from this note. Two ways to be safe to detach: it still has another note
    // attribution once this note's is set aside (hasAttributionBeyondCurrentNote), or it's been
    // an orphan before and can safely return to that state (SavedWord.hasBeenOrphaned). Neither
    // holding means this note is the only thing that's ever backed the word, so removing it here
    // has nothing to fall back to — a real, full unsave.
    fileprivate func vocabRowWouldFullyRemove(_ identity: String) -> Bool {
        if hasAttributionBeyondCurrentNote(normalizedSurface: identity) {
            return false
        }
        let hasBeenOrphaned = wordsStore.words.first { $0.surface == identity || $0.encounteredSurfaces.contains(identity) }?.hasBeenOrphaned ?? false
        return hasBeenOrphaned == false
    }
}
