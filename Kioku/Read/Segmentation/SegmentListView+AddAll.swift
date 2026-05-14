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

        // Dedupe by normalized surface so the dictionary is only consulted once per distinct word.
        var seenSurfaces = Set<String>()
        var orderedSurfaces: [String] = []
        var unresolvedPairs: [(surface: String, lemma: String)] = []
        orderedSurfaces.reserveCapacity(rows.count)

        for row in rows {
            let normalizedSurface = normalizedSurfaceForFiltering(row.edge.surface)
            guard normalizedSurface.isEmpty == false,
                  seenSurfaces.contains(normalizedSurface) == false else {
                continue
            }
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
            let addedCount = commitAddAllVisibleWords(orderedSurfaces: orderedSurfaces, lookup: lookup)
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
        lookup: [String: Int64]
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

            if let existingIndex = indexByEntryID[entryID] {
                guard let noteID = sourceNoteID else {
                    continue
                }

                let existingEntry = entries[existingIndex]
                var noteIDs = Set(existingEntry.sourceNoteIDs)
                if noteIDs.contains(noteID) {
                    continue
                }

                noteIDs.insert(noteID)
                entries[existingIndex] = SavedWord(
                    canonicalEntryID: existingEntry.canonicalEntryID,
                    surface: existingEntry.surface,
                    sourceNoteIDs: noteIDs.sorted { $0.uuidString < $1.uuidString }
                )
            } else {
                let noteIDs: [UUID] = sourceNoteID.map { [$0] } ?? []
                indexByEntryID[entryID] = entries.count
                entries.append(
                    SavedWord(
                        canonicalEntryID: entryID,
                        surface: normalizedSurface,
                        sourceNoteIDs: noteIDs
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
