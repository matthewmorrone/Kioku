import SwiftUI

// Wraps a non-Sendable closure so it can be captured into a @Sendable background
// dispatch. Safe here because lemmaForSurface only reads from nonisolated Segmenter.
nonisolated private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(value: T) { self.value = value }
}

// Saved-word state management for SegmentListView: per-surface star toggling,
// canonical-id-backed persistence into WordsStore, and the in-memory caches
// (`savedWordSurfaces`, `savedWordSourceNoteIDsBySurface`) that drive star
// rendering. Includes the legacy-card lemma expansion in `applySavedWordState`
// so historical conjugated saves still light up the lemma row.
extension SegmentListView {
    // Toggles one segment surface in the saved-word list storage.
    // `lemma` is the dictionary headword. New cards store `surface = lemma`
    // (lemma-normalized at save time), with the user-clicked surface added to
    // `encounteredSurfaces`. Existing cards have only their encountered set
    // updated — the stored surface is preserved.
    func toggleSavedWord(_ surface: String, lemma: String = "") {
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

    // Delegates the save/unsave mutation to `WordsStore.toggle` (which owns the bookkeeping
    // semantics) and then refreshes the segment list's per-surface star caches. The lemma
    // form is preferred as the card's stored surface so the lemma row stars correctly; the
    // user's clicked surface is captured in `encounteredSurfaces` so per-surface star state
    // still distinguishes which conjugation was tapped.
    func toggleSavedWord(canonicalEntryID: Int64, normalizedSurface: String, normalizedLemma: String) {
        let storedSurface = normalizedLemma.isEmpty ? normalizedSurface : normalizedLemma
        // Default sense IDs are only consumed in WordsStore.toggle's create-new-card
        // branch — for an existing card the toggle just flips encountered-surface /
        // note membership. So we only need to pay the 4-query SQL materialization
        // (lookupEntry → fetchHeader + kanji + kana + senses) on the first save of
        // a never-saved word. For toggles of existing cards (the common case: unstar,
        // re-star, toggle from another note) we skip the SQL entirely and the tap
        // path is purely in-memory.
        let cardAlreadyExists = wordsStore.words.contains { $0.canonicalEntryID == canonicalEntryID }
        let senseIDs: [Int64]
        if cardAlreadyExists {
            senseIDs = []
        } else if let store = dictionaryStore,
                  let resolved = try? store.lookupEntry(entryID: canonicalEntryID) {
            senseIDs = DefaultSenseSelection.defaultSelectedSenseIDs(for: resolved)
        } else {
            senseIDs = []
        }
        wordsStore.toggle(
            canonicalEntryID: canonicalEntryID,
            storedSurface: storedSurface,
            encounteredSurface: normalizedSurface,
            sourceNoteID: sourceNoteID,
            defaultSenseIDs: senseIDs
        )
        applySavedWordState(entries: wordsStore.words)
    }

    // Refreshes star-state caches from the in-memory WordsStore snapshot, which already mirrors
    // persistent storage. Going through WordsStore avoids a redundant UserDefaults read + JSON
    // decode + normalize on view appearance.
    //
    // The actual computation hops to a background queue because for users with
    // hundreds of saved words it iterates each one and calls
    // `segmenter.preferredLemma(for: storedSurface)` (legacy-card detection),
    // which is the dominant cost when the sheet first appears. Assignment of
    // the four resulting @State dicts hops back to main. The sheet paints with
    // empty caches first; stars light up a fraction of a second later when the
    // assignment arrives.
    func loadSavedWordsFromStorage() {
        let entries = wordsStore.words
        let resolverBox = UncheckedSendableBox(value: lemmaForSurface)
        let cacheSnapshot = lemmaCacheByStoredSurface
        DispatchQueue.global(qos: .userInitiated).async {
            let (state, updatedCache) = Self.computeSavedWordState(
                entries: entries,
                lemmaResolver: resolverBox.value,
                lemmaCache: cacheSnapshot
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    savedWordEntryIDs = state.savedWordEntryIDs
                    savedWordSourceNoteIDsByEntryID = state.savedWordSourceNoteIDsByEntryID
                    savedWordSourceNoteIDsBySurface = state.savedWordSourceNoteIDsBySurface
                    savedWordSurfaces = state.savedWordSurfaces
                    lemmaCacheByStoredSurface.merge(updatedCache) { _, new in new }
                }
            }
        }
    }

    // Snapshot of the four saved-word star-state caches that `applySavedWordState`
    // and its off-main twin compute. Bundled so the background path can return
    // them in one go and the main-thread assignment hopper applies them in one
    // batch (no intermediate UI re-renders showing partial state).
    struct ComputedSavedWordState {
        var savedWordEntryIDs: Set<Int64>
        var savedWordSourceNoteIDsByEntryID: [Int64: Set<UUID>]
        var savedWordSourceNoteIDsBySurface: [String: Set<UUID>]
        var savedWordSurfaces: Set<String>
    }

    // Pure computation extracted from `applySavedWordState` so it can run on
    // any thread. The `lemmaResolver` closure must be safe to call off-main
    // (Segmenter is `@unchecked Sendable`, so the production wire-up is fine).
    // `lemmaCache` is a snapshot of `lemmaCacheByStoredSurface` to short-circuit
    // re-segmenting storedSurfaces we've already resolved this session.
    nonisolated static func computeSavedWordState(
        entries: [SavedWord],
        lemmaResolver: (String) -> String?,
        lemmaCache: [String: String]
    ) -> (ComputedSavedWordState, [String: String]) {
        var savedWordEntryIDs = Set<Int64>()
        var sourceNoteIDsByEntryID: [Int64: Set<UUID>] = [:]
        var sourceNoteIDsBySurface: [String: Set<UUID>] = [:]
        var unionEncountered = Set<String>()
        var updatedLemmaCache = lemmaCache

        savedWordEntryIDs.reserveCapacity(entries.count)
        sourceNoteIDsByEntryID.reserveCapacity(entries.count)

        for entry in entries {
            savedWordEntryIDs.insert(entry.canonicalEntryID)
            let entryNoteIDs = Set(entry.sourceNoteIDs)
            sourceNoteIDsByEntryID[entry.canonicalEntryID] = entryNoteIDs

            var expandedEncountered = entry.encounteredSurfaces
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
                .reduce(into: Set<String>()) { $0.insert($1) }

            let storedSurface = entry.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            // Resolve storedSurface→lemma through the cache. New stored surfaces
            // get one segmenter call and the result is memoized for the rest of
            // the session — subsequent star toggles don't re-segment them.
            let storedSurfaceLemma: String = {
                if let cached = updatedLemmaCache[storedSurface] {
                    return cached
                }
                let resolved = (lemmaResolver(storedSurface) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                updatedLemmaCache[storedSurface] = resolved
                return resolved
            }()

            if storedSurface.isEmpty == false,
               storedSurfaceLemma.isEmpty == false,
               storedSurface != storedSurfaceLemma {
                expandedEncountered.insert(storedSurface)
                expandedEncountered.insert(storedSurfaceLemma)
            }

            for surface in expandedEncountered {
                unionEncountered.insert(surface)
                let merged = sourceNoteIDsBySurface[surface, default: Set<UUID>()].union(entryNoteIDs)
                sourceNoteIDsBySurface[surface] = merged
            }
        }

        let state = ComputedSavedWordState(
            savedWordEntryIDs: savedWordEntryIDs,
            savedWordSourceNoteIDsByEntryID: sourceNoteIDsByEntryID,
            savedWordSourceNoteIDsBySurface: sourceNoteIDsBySurface,
            savedWordSurfaces: unionEncountered
        )
        return (state, updatedLemmaCache)
    }

    // Applies saved-word state used by star rendering from one canonical storage snapshot.
    //
    // (Shared favorited-state predicate lives on ComputedSavedWordState below so the extract-words
    // stars, the in-text glow, and the lookup-sheet star all answer "is this favorited?" identically.)
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
        // Synchronous toggle-time rebuild. Uses the in-session
        // `lemmaCacheByStoredSurface` so previously-seen storedSurfaces don't
        // re-segment on every star tap. For a fresh card, the segmenter call
        // happens once and the result is memoized for the rest of the sheet's
        // lifetime. Initial-load path (`loadSavedWordsFromStorage`) hops the
        // whole computation off-main; this synchronous path stays on main so
        // the optimistic flip + canonical rebuild stay race-free across rapid
        // taps.
        let (state, updatedCache) = Self.computeSavedWordState(
            entries: entries,
            lemmaResolver: lemmaForSurface,
            lemmaCache: lemmaCacheByStoredSurface
        )
        savedWordEntryIDs = state.savedWordEntryIDs
        savedWordSurfaces = state.savedWordSurfaces
        savedWordSourceNoteIDsByEntryID = state.savedWordSourceNoteIDsByEntryID
        savedWordSourceNoteIDsBySurface = state.savedWordSourceNoteIDsBySurface
        lemmaCacheByStoredSurface = updatedCache
    }

    // The four star predicates now delegate to the shared implementation on ComputedSavedWordState
    // (below), so the extract-words stars use the EXACT same logic the glow and lookup-sheet star
    // use. `currentSavedState` just wraps this view's @State caches into that value type — no
    // recomputation.
    private var currentSavedState: ComputedSavedWordState {
        ComputedSavedWordState(
            savedWordEntryIDs: savedWordEntryIDs,
            savedWordSourceNoteIDsByEntryID: savedWordSourceNoteIDsByEntryID,
            savedWordSourceNoteIDsBySurface: savedWordSourceNoteIDsBySurface,
            savedWordSurfaces: savedWordSurfaces
        )
    }

    // Per-surface "saved anywhere" check (lemma-bridged).
    func isSavedSurface(normalizedSurface: String) -> Bool {
        currentSavedState.isSavedSurface(normalizedSurface, lemmaResolver: lemmaForSurface)
    }

    // True when the queried surface is saved AND attributed to the active note.
    func isSavedForCurrentNote(normalizedSurface: String) -> Bool {
        currentSavedState.isSavedForNote(normalizedSurface, noteID: sourceNoteID, lemmaResolver: lemmaForSurface)
    }

    // True when the surface is saved but its attributions don't include the
    // active note — the "saved elsewhere" / yellow-hollow visual state.
    func isSavedForOtherNotes(normalizedSurface: String) -> Bool {
        currentSavedState.isSavedForOtherNotes(normalizedSurface, noteID: sourceNoteID, lemmaResolver: lemmaForSurface)
    }
}

// Shared favorited-state predicate. This is THE single source of truth for "is this surface
// favorited (and how)", used by the extract-words list stars, the in-text favorited glow, and the
// lookup-sheet star — so all three stay 1:1 by construction. Operates purely on the snapshot value
// type, so any caller that can build a ComputedSavedWordState (from WordsStore.words) gets the same
// answers without depending on SegmentListView's @State.
extension SegmentListView.ComputedSavedWordState {
    // Resolves a queried surface to the key its saved state lives under, bridging conjugation →
    // lemma: direct hit first, else deinflect and try the lemma. nil when neither form is saved.
    func resolvedSavedKey(for normalizedSurface: String, lemmaResolver: (String) -> String?) -> String? {
        if savedWordSurfaces.contains(normalizedSurface) {
            return normalizedSurface
        }
        guard let lemma = lemmaResolver(normalizedSurface)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              lemma.isEmpty == false,
              lemma != normalizedSurface,
              savedWordSurfaces.contains(lemma)
        else { return nil }
        return lemma
    }

    // Saved under any note (or with no note attribution).
    func isSavedSurface(_ normalizedSurface: String, lemmaResolver: (String) -> String?) -> Bool {
        resolvedSavedKey(for: normalizedSurface, lemmaResolver: lemmaResolver) != nil
    }

    // Saved AND attributed to `noteID` (nil note context collapses to "saved anywhere").
    func isSavedForNote(_ normalizedSurface: String, noteID: UUID?, lemmaResolver: (String) -> String?) -> Bool {
        guard let noteID else {
            return isSavedSurface(normalizedSurface, lemmaResolver: lemmaResolver)
        }
        guard let key = resolvedSavedKey(for: normalizedSurface, lemmaResolver: lemmaResolver),
              let notes = savedWordSourceNoteIDsBySurface[key] else { return false }
        return notes.contains(noteID)
    }

    // Saved but NOT attributed to `noteID` — the "saved elsewhere" hollow-yellow state.
    func isSavedForOtherNotes(_ normalizedSurface: String, noteID: UUID?, lemmaResolver: (String) -> String?) -> Bool {
        guard let noteID else { return false }
        guard let key = resolvedSavedKey(for: normalizedSurface, lemmaResolver: lemmaResolver),
              let notes = savedWordSourceNoteIDsBySurface[key] else { return false }
        return notes.isEmpty == false && notes.contains(noteID) == false
    }

    // The "filled star" predicate the extract-words list renders (isSavedForCurrentNote OR saved
    // with no note attribution at all). The in-text glow mirrors exactly this, giving the 1:1
    // correspondence between starred words and highlighted words.
    func isStarFilled(_ normalizedSurface: String, noteID: UUID?, lemmaResolver: (String) -> String?) -> Bool {
        if isSavedForNote(normalizedSurface, noteID: noteID, lemmaResolver: lemmaResolver) {
            return true
        }
        return isSavedSurface(normalizedSurface, lemmaResolver: lemmaResolver)
            && isSavedForOtherNotes(normalizedSurface, noteID: noteID, lemmaResolver: lemmaResolver) == false
    }
}
