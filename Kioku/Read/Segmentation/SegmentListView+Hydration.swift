import SwiftUI

// Wraps a non-Sendable closure so it can be captured into a @Sendable background
// dispatch. Safe here because lemmaForSurface only reads from nonisolated Segmenter.
nonisolated private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(value: T) { self.value = value }
}

// Canonical-entry-id hydration and word-detail presentation for SegmentListView.
// Star rendering and tap-to-detail both rely on the surface → canonical-id map
// populated here off the main thread, with a synchronous fast-path when the
// row is already cached.
extension SegmentListView {
    // Resolves the canonical dictionary entry for a tapped surface and presents the word detail sheet.
    // Reuses the canonical-id cache populated for star rendering, falling back to a hydrate pass when
    // the row hasn't been resolved yet (e.g. fresh sheet, mid-scroll segment).
    func openWordDetail(for surface: String, lemma: String) {
        let normalizedSurface = normalizedSurfaceForFiltering(surface)
        guard normalizedSurface.isEmpty == false else { return }

        if let entryID = canonicalEntryIDBySurface[normalizedSurface] {
            presentWordDetail(canonicalEntryID: entryID, surface: normalizedSurface)
            return
        }

        // Fallback path: if the surface matches a saved entry's stored or encountered surface,
        // open detail for THAT card directly. Skips the dictionary hydration for words that
        // can't round-trip through DictionaryStore.lookupFirstEntryID (archaic kana, dict-build
        // drift) — without this, tapping a row with yellow-hollow star silently no-ops.
        if let entryID = canonicalEntryIDFromSavedEntries(for: normalizedSurface) {
            canonicalEntryIDBySurface[normalizedSurface] = entryID
            presentWordDetail(canonicalEntryID: entryID, surface: normalizedSurface)
            return
        }

        let normalizedLemma = normalizedSurfaceForFiltering(lemma)
        hydrateCanonicalEntryIDs(for: [(surface: normalizedSurface, lemma: normalizedLemma)]) { hydratedEntryIDs in
            if hydratedEntryIDs.isEmpty == false {
                canonicalEntryIDBySurface.merge(hydratedEntryIDs) { current, _ in current }
            }
            if let entryID = hydratedEntryIDs[normalizedSurface] {
                presentWordDetail(canonicalEntryID: entryID, surface: normalizedSurface)
                return
            }
            // Last-resort fallback after hydration: same saved-entries lookup as above. Useful
            // when canonicalEntryIDBySurface was cleared between the two checks.
            if let entryID = canonicalEntryIDFromSavedEntries(for: normalizedSurface) {
                canonicalEntryIDBySurface[normalizedSurface] = entryID
                presentWordDetail(canonicalEntryID: entryID, surface: normalizedSurface)
            }
        }
    }

    // Presents the in-app lookup sheet (SegmentLookupSheet) for the tapped row. Mirrors the
    // tap-from-read-view flow but with no neighbor/swipe context — list rows aren't spatially
    // adjacent the way inline segments are. The sheet's "see details" chevron uses the
    // sheetOpenWordDetail callback to navigate to WordDetailView, so the user's mental model
    // (tap = sheet, Word Details = full page) holds end-to-end.
    func openLookupSheet(for surface: String, lemma: String) {
        let normalizedSurface = normalizedSurfaceForFiltering(surface)
        guard normalizedSurface.isEmpty == false else { return }

        // Resolve canonical entry ID using the same fallback chain as openWordDetail: cache →
        // saved-entries index → dictionary hydration. Without this the sheet would render an
        // empty shell for surfaces that don't directly resolve in the dictionary right now.
        if let entryID = canonicalEntryIDBySurface[normalizedSurface] {
            presentLookupSheet(canonicalEntryID: entryID, surface: normalizedSurface)
            return
        }
        if let entryID = canonicalEntryIDFromSavedEntries(for: normalizedSurface) {
            canonicalEntryIDBySurface[normalizedSurface] = entryID
            presentLookupSheet(canonicalEntryID: entryID, surface: normalizedSurface)
            return
        }
        let normalizedLemma = normalizedSurfaceForFiltering(lemma)
        hydrateCanonicalEntryIDs(for: [(surface: normalizedSurface, lemma: normalizedLemma)]) { hydratedEntryIDs in
            if hydratedEntryIDs.isEmpty == false {
                canonicalEntryIDBySurface.merge(hydratedEntryIDs) { current, _ in current }
            }
            if let entryID = hydratedEntryIDs[normalizedSurface] {
                presentLookupSheet(canonicalEntryID: entryID, surface: normalizedSurface)
            } else if let entryID = canonicalEntryIDFromSavedEntries(for: normalizedSurface) {
                canonicalEntryIDBySurface[normalizedSurface] = entryID
                presentLookupSheet(canonicalEntryID: entryID, surface: normalizedSurface)
            }
        }
    }

    // Drives SegmentLookupSheet with the minimum provider set we need from list context: the
    // dictionary entry (via canonical-id SQL lookup), kana readings projected from its forms,
    // save state from the existing per-surface caches, and the "open word detail" callback
    // that lifts the user from the sheet to the full WordDetailView page.
    func presentLookupSheet(canonicalEntryID: Int64, surface: String) {
        guard let dictionaryStore else { return }
        let normalizedSurface = surface

        SegmentLookupSheet.shared.presentSheet(
            surface: normalizedSurface,
            leftNeighborSurface: nil,
            rightNeighborSurface: nil,
            // Readings are the kana_forms of the entry; sheet header renders furigana from these.
            sheetReadingsProvider: {
                guard let entry = try? dictionaryStore.lookupEntry(entryID: canonicalEntryID) else { return [] }
                return entry.kanaForms.map(\.text)
            },
            // Headword + senses come straight from the dictionary entry the row identifies.
            sheetDictionaryEntryProvider: {
                try? dictionaryStore.lookupEntry(entryID: canonicalEntryID)
            },
            // Wire the star button on the sheet to the same per-surface toggle the row uses.
            sheetIsSavedProvider: {
                isSavedForCurrentNote(normalizedSurface: normalizedSurface)
            },
            sheetSaveToggle: {
                toggleSavedWord(normalizedSurface)
            },
            // The chevron "see details" still navigates to the full page — keeps the user's
            // tap=sheet, details=page mental model intact.
            sheetOpenWordDetail: {
                presentWordDetail(canonicalEntryID: canonicalEntryID, surface: normalizedSurface)
            }
        )
    }

    // Walks wordsStore.words for a saved entry whose stored or encountered surface matches the
    // queried (already-normalized) surface, returning that entry's canonical id. The match is
    // O(N + encounteredCount); negligible vs the SQL hydration path we're falling back from.
    // Shared by openWordDetail and Add All's commit step so both paths handle dict drift the
    // same way.
    func canonicalEntryIDFromSavedEntries(for normalizedSurface: String) -> Int64? {
        for entry in wordsStore.words {
            let stored = entry.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            if stored == normalizedSurface { return entry.canonicalEntryID }
            for surface in entry.encounteredSurfaces {
                if surface.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedSurface {
                    return entry.canonicalEntryID
                }
            }
        }
        return nil
    }

    // Picks the existing SavedWord for an entry id when present so list memberships and personal
    // notes show through; otherwise builds a transient SavedWord that drives the detail screen
    // without persisting anything.
    func presentWordDetail(canonicalEntryID: Int64, surface: String) {
        if let existing = wordsStore.words.first(where: { $0.canonicalEntryID == canonicalEntryID }) {
            detailWord = existing
        } else {
            detailWord = SavedWord(canonicalEntryID: canonicalEntryID, surface: surface)
        }
    }

    // Off-main lemma hydration for every edge surface in the current segment list.
    // Populates `lemmaCacheByEdgeSurface` so `resolvedRowSurface` and per-row
    // `rowLemma` lookups become O(1) hashmap hits — the lemma toggle and scroll
    // paths previously paid one `segmenter.preferredLemma(for:)` call (trie +
    // deinflector) per row PER body re-evaluation, which dominated those paths
    // for long notes. Segmenter is `@unchecked Sendable` (see Segmenter.swift)
    // so it's safe to call from a background queue; we just hop assignment of
    // the @State dict back to main.
    //
    // Re-runs whenever the edge surfaces change; the deduplicated Set keeps the
    // background workload proportional to distinct surfaces, not row count.
    func hydrateLemmasForEdgeSurfaces() {
        let distinctSurfaces = Set(edges.map(\.surface))
            .subtracting(lemmaCacheByEdgeSurface.keys)
        guard distinctSurfaces.isEmpty == false else { return }

        // The lemmaForSurface closure is constructed on MainActor but reads only
        // from nonisolated Segmenter state, so calling it off main is safe at
        // runtime even though the type system can't prove it.
        let resolverBox = UncheckedSendableBox(value: lemmaForSurface)
        DispatchQueue.global(qos: .userInitiated).async {
            let resolver = resolverBox.value
            var resolved: [String: String] = [:]
            resolved.reserveCapacity(distinctSurfaces.count)
            for surface in distinctSurfaces {
                resolved[surface] = resolver(surface) ?? ""
            }
            // Task { @MainActor in … } instead of DispatchQueue.main.async so the
            // assignment is compile-time guaranteed to land on the main actor —
            // matches the pattern `hydrateCanonicalEntryIDs` uses (migrated for
            // Swift 6 in 500dd9d) and protects against future refactors that
            // might drop the hop without the compiler catching it.
            Task { @MainActor in
                lemmaCacheByEdgeSurface.merge(resolved) { current, _ in current }
            }
        }
    }

    // Schedules canonical-id hydration for visible rows so lookups never block sheet presentation.
    func scheduleCanonicalEntryIDHydrationForVisibleRows() {
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
        onComplete: @escaping @Sendable @MainActor ([String: Int64]) -> Void
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

            Task { @MainActor in
                onComplete(resolvedEntryIDs)
            }
        }
    }
}
