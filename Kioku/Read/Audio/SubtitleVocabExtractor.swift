import Foundation

// Turns subtitle text into the set of vocabulary an episode requires: segment every line, lemmatize,
// drop function words, dedupe by dictionary form, and resolve each form to a canonical dictionary
// entry so it can be saved as a SavedWord. This is the heart of the "subtitle → vocab list" feature
// (Feature A) and is deliberately pure — it takes a segmenter and dictionary store as inputs and
// returns plain values, so it can run on a detached task off the main actor and be unit-tested
// without any UI or store wiring.
//
// Behavior (per the agreed design): EVERY unique dictionary-resolvable content lemma is kept — no
// frequency filter, no known/unknown subtraction. The only exclusions are (1) tokens that don't
// resolve through the dictionary (punctuation, character names, novel proper nouns — they have no
// entry to attach to) and (2) grammatical particles, removed via the canonical ParticleSettings
// allowlist the rest of the app already uses.
nonisolated enum SubtitleVocabExtractor {
    // One unique vocabulary item: its dictionary (lemma) form, the resolved canonical entry id, and
    // every surface form actually seen in the episode (食べた, 食べる, …) so the saved card stars on
    // each encountered form.
    struct ExtractedVocab: Equatable {
        let lemma: String
        let canonicalEntryID: Int64
        let encounteredSurfaces: Set<String>
    }

    // Segments and lemmatizes `text`, returning unique resolvable content vocab in first-seen order.
    // Convenience over the edges-based core: segments the whole text once. The caller that also needs
    // the segmentation (to persist it on the note) should call `extract(fromEdges:)` directly with
    // the selected edges so the body is only segmented once.
    static func extract(
        from text: String,
        segmenter: any TextSegmenting,
        dictionaryStore: DictionaryStore?
    ) -> [ExtractedVocab] {
        extract(fromEdges: segmenter.longestMatchEdges(for: text), dictionaryStore: dictionaryStore)
    }

    // Core extraction over an already-computed selected-edge path (the greedy segmentation, which
    // tiles the whole body). Newline/boundary edges are non-dictionary and skipped automatically, so
    // operating on whole-body edges is equivalent to per-line segmentation but avoids a second pass.
    static func extract(
        fromEdges edges: [LatticeEdge],
        dictionaryStore: DictionaryStore?
    ) -> [ExtractedVocab] {
        let particles = ParticleSettings.allowed()

        // lemma → surfaces seen, plus an order list so the result is stable and reviewable.
        var surfacesByLemma: [String: Set<String>] = [:]
        var lemmaOrder: [String] = []

        for edge in edges {
            // Only dictionary-backed edges can become a SavedWord; skip punctuation, whitespace
            // breaks, and unknown runs (names, novel proper nouns).
            guard edge.isDictionaryMatch else { continue }

            let lemma = edge.lemma.isEmpty ? edge.surface : edge.lemma
            guard lemma.isEmpty == false else { continue }

            // Exclude grammatical particles via the canonical allowlist — by lemma and by the
            // raw surface, so both は and a conjugated-away particle form drop out.
            if particles.contains(lemma) || particles.contains(edge.surface) { continue }

            if surfacesByLemma[lemma] == nil {
                surfacesByLemma[lemma] = []
                lemmaOrder.append(lemma)
            }
            surfacesByLemma[lemma]?.insert(edge.surface)
        }

        guard lemmaOrder.isEmpty == false else { return [] }

        // Resolve every lemma to a canonical entry id in one batched in-memory lookup. Lemmas that
        // don't resolve are dropped — there's no dictionary entry to attach a saved word to.
        let entryIDByLemma = dictionaryStore?.lookupFirstEntryIDs(surfaces: lemmaOrder) ?? [:]

        return lemmaOrder.compactMap { lemma in
            guard let entryID = entryIDByLemma[lemma] else { return nil }
            return ExtractedVocab(
                lemma: lemma,
                canonicalEntryID: entryID,
                encounteredSurfaces: surfacesByLemma[lemma] ?? [lemma]
            )
        }
    }
}
