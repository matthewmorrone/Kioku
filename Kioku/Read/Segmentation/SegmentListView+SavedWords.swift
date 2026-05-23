import SwiftUI

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
    func toggleSavedWord(canonicalEntryID: Int64, normalizedSurface: String, normalizedLemma: String) {
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
    func loadSavedWordsFromStorage() {
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
    func isSavedSurface(normalizedSurface: String) -> Bool {
        savedWordSurfaces.contains(normalizedSurface)
    }

    // True when the queried surface is saved AND attributed to the active note.
    func isSavedForCurrentNote(normalizedSurface: String) -> Bool {
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
    func isSavedForOtherNotes(normalizedSurface: String) -> Bool {
        guard let sourceNoteID else {
            return false
        }
        guard let sourceNoteIDs = savedWordSourceNoteIDsBySurface[normalizedSurface] else {
            return false
        }
        return sourceNoteIDs.isEmpty == false && sourceNoteIDs.contains(sourceNoteID) == false
    }
}
