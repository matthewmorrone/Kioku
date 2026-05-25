import SwiftUI

// Hosts the "Add All" multi-word save flow for SegmentListView so the main view file
// stays under the per-file line budget.
extension SegmentListView {
    // Stages the visible row surfaces for save with a paced UI: small batches stagger
    // star fade-ins, large batches flip stars at once and rely on a "Saving…" indicator
    // while persistence runs.
    func addAllVisibleWords() {
        let rows = displayRows
        guard rows.isEmpty == false else {
            return
        }

        // Dedupe by row identity (lemma when resolved, surface fallback) so the
        // dictionary is only consulted once per distinct word and 食べた / 食べる /
        // 食べない collapse to one card of 食べる.
        var seenSurfaces = Set<String>()
        var orderedSurfaces: [String] = []
        // Per-row identity → the raw edge surface that produced it. Add All
        // records every encountered conjugation on the resulting card so the
        // user can later see "I tapped both 食べた and 食べない for this entry."
        var encounteredByIdentity: [String: Set<String>] = [:]
        var unresolvedPairs: [(surface: String, lemma: String)] = []
        orderedSurfaces.reserveCapacity(rows.count)

        for row in rows {
            let normalizedSurface = normalizedSurfaceForFiltering(resolvedRowSurface(for: row.edge))
            guard normalizedSurface.isEmpty == false else { continue }
            let rawEdgeSurface = normalizedSurfaceForFiltering(row.edge.surface)
            if rawEdgeSurface.isEmpty == false {
                encounteredByIdentity[normalizedSurface, default: Set()].insert(rawEdgeSurface)
            }
            guard seenSurfaces.contains(normalizedSurface) == false else { continue }
            seenSurfaces.insert(normalizedSurface)
            orderedSurfaces.append(normalizedSurface)
            if canonicalEntryIDBySurface[normalizedSurface] == nil {
                unresolvedPairs.append((
                    surface: normalizedSurface,
                    lemma: normalizedSurfaceForFiltering(lemmaForSurface(row.edge.surface) ?? "")
                ))
            }
        }

        let newSurfaces = orderedSurfaces.filter { savedWordSurfaces.contains($0) == false }
        let total = newSurfaces.count

        addAllFeedbackTask?.cancel()
        addAllFeedbackTask = Task { @MainActor in
            // Stagger per-row star fade-ins for small batches so the action is visibly happening
            // rather than appearing instant. The total stagger window is bounded so a 1000-row
            // selection no longer drags for ~8s at the previous 8ms-per-item floor; large batches
            // skip the stagger entirely and rely on the "Saving…" indicator during commit instead.
            let staggerCutoff = 60
            if total > 0 && total <= staggerCutoff {
                let totalWindowNanos: UInt64 = 1_200_000_000
                // Cap per-item delay so a 2-row selection doesn't sleep ~600ms per row; the total
                // window still tightens for larger batches because the divisor wins under the cap.
                let perItemNanos = min(UInt64(40_000_000), totalWindowNanos / UInt64(total))
                for (idx, surface) in newSurfaces.enumerated() {
                    if Task.isCancelled { return }
                    _ = withAnimation(.easeOut(duration: 0.15)) {
                        savedWordSurfaces.insert(surface)
                    }
                    addAllFeedbackMessage = total == 1
                        ? "Adding 1 word…"
                        : "Adding \(idx + 1)/\(total)…"
                    if idx + 1 < total {
                        try? await Task.sleep(nanoseconds: perItemNanos)
                    }
                }
            } else if total > 0 {
                // Above the stagger cutoff: flip all stars at once and let the commit step's
                // "Saving…" indicator carry the user feedback while persistence runs.
                withAnimation(.easeOut(duration: 0.2)) {
                    for surface in newSurfaces {
                        savedWordSurfaces.insert(surface)
                    }
                }
                addAllFeedbackMessage = "Adding \(total) words…"
            }
            if Task.isCancelled { return }

            // Resolve any missing canonical IDs (typically a no-op since prewarm runs on appear),
            // then commit. With batch SQL the hydrate step is ~10ms even from cold.
            let cachedEntryIDs = canonicalEntryIDBySurface
            let lookup: [String: Int64]
            if unresolvedPairs.isEmpty {
                lookup = cachedEntryIDs
            } else {
                lookup = await withCheckedContinuation { continuation in
                    hydrateCanonicalEntryIDs(for: unresolvedPairs) { hydratedEntryIDs in
                        var merged = cachedEntryIDs
                        for (surface, entryID) in hydratedEntryIDs where merged[surface] == nil {
                            merged[surface] = entryID
                        }
                        if hydratedEntryIDs.isEmpty == false {
                            canonicalEntryIDBySurface.merge(hydratedEntryIDs) { current, _ in current }
                        }
                        continuation.resume(returning: merged)
                    }
                }
            }
            if Task.isCancelled { return }

            // Distinct "Saving…" indicator so the user knows persistence is running rather than
            // wondering why the previous "Adding N/N…" message has stalled.
            addAllFeedbackMessage = "Saving…"
            let addedCount = commitAddAllVisibleWords(
                orderedSurfaces: orderedSurfaces,
                lookup: lookup,
                encounteredByIdentity: encounteredByIdentity
            )
            if Task.isCancelled { return }

            // Final toast: report the real count from the commit step (which only counts
            // entries that resolved + actually changed storage).
            if addedCount == 0 {
                addAllFeedbackMessage = "No new words added"
            } else if addedCount == 1 {
                addAllFeedbackMessage = "Added 1 word"
            } else {
                addAllFeedbackMessage = "Added \(addedCount) words"
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.2)) {
                addAllFeedbackMessage = nil
            }
        }
    }

    // Persists the saved-word entries derived from one Add-All invocation. Returns the number of
    // entries that were actually added or note-linked so the caller can drive its toast/UI; the
    // toast lifecycle is owned by addAllVisibleWords' staggered task, not here.
    //
    // The merge runs synchronously on the main actor (O(N+M) — fast even for tens of thousands of
    // saved words) so concurrent edits like a single-tap toggle landing during the Saving… phase
    // can't be lost; only the JSON encode + UserDefaults write defers to a background queue
    // inside WordsStore.persist, which was the actual source of the post-stagger freeze.
    @discardableResult
    func commitAddAllVisibleWords(
        orderedSurfaces: [String],
        lookup: [String: Int64],
        encounteredByIdentity: [String: Set<String>]
    ) -> Int {
        var entries = wordsStore.words
        // Index by canonical entry id to keep the merge step O(N+M) when the saved-word list is large.
        var indexByEntryID: [Int64: Int] = [:]
        indexByEntryID.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            indexByEntryID[entry.canonicalEntryID] = index
        }

        var addedCount = 0

        for normalizedSurface in orderedSurfaces {
            guard let entryID = lookup[normalizedSurface] else {
                continue
            }

            // Every conjugation seen for this card identity in this Add All pass,
            // plus the identity itself (so the lemma always queries as saved on
            // the per-surface star map). Single-tap save already includes the
            // identity in encountered; we match that here.
            var newlyEncountered = encounteredByIdentity[normalizedSurface] ?? Set()
            newlyEncountered.insert(normalizedSurface)

            if let existingIndex = indexByEntryID[entryID] {
                let existingEntry = entries[existingIndex]
                var noteIDs = Set(existingEntry.sourceNoteIDs)
                var encountered = existingEntry.encounteredSurfaces
                let needsNote = sourceNoteID.map { noteIDs.contains($0) == false } ?? false
                let needsSurface = newlyEncountered.subtracting(encountered).isEmpty == false
                if needsNote == false && needsSurface == false {
                    continue
                }
                if let sourceNoteID, needsNote {
                    noteIDs.insert(sourceNoteID)
                }
                if needsSurface {
                    encountered.formUnion(newlyEncountered)
                }
                entries[existingIndex] = SavedWord(
                    canonicalEntryID: existingEntry.canonicalEntryID,
                    surface: existingEntry.surface,
                    sourceNoteIDs: noteIDs.sorted { $0.uuidString < $1.uuidString },
                    wordListIDs: existingEntry.wordListIDs,
                    personalNote: existingEntry.personalNote,
                    savedAt: existingEntry.savedAt,
                    selectedSenseIDs: existingEntry.selectedSenseIDs,
                    selectedGlosses: existingEntry.selectedGlosses,
                    encounteredSurfaces: encountered
                )
            } else {
                let noteIDs: [UUID] = sourceNoteID.map { [$0] } ?? []
                indexByEntryID[entryID] = entries.count
                // New card: stored surface is the canonical lemma (= the row
                // identity, which `resolvedRowSurface` produces lemma-first).
                // Encountered set captures every conjugation the user just saw
                // in the segment list (e.g. 食べた + 食べない both end up here),
                // so the per-surface star map lights both rows on this note.
                entries.append(
                    SavedWord(
                        canonicalEntryID: entryID,
                        surface: normalizedSurface,
                        sourceNoteIDs: noteIDs,
                        encounteredSurfaces: newlyEncountered
                    )
                )
            }

            addedCount += 1
        }

        wordsStore.replaceAll(with: entries)
        applySavedWordState(entries: wordsStore.words)
        return addedCount
    }
}
