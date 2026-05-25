import SwiftUI

// Row-identity, normalization, and visibility filters for SegmentListView.
// Encapsulates how `displayRows` derives the visible list — punctuation/symbol
// exclusion, particle dedupe, duplicate dedupe — plus the lemma-vs-surface
// identity resolution that every save/star/tap operation funnels through.
extension SegmentListView {
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
    func isCommonParticle(_ surface: String) -> Bool {
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
    func isPurePunctuationOrSymbol(_ surface: String) -> Bool {
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
    // Returns the lemma candidates for `edgeSurface`. POS gating to keep only
    // conjugating classes (verb / i-adjective) when deinflection was applied is
    // done inside `Segmenter.lemmaCandidates` using its in-memory
    // partOfSpeechByEntryID map, so this is just a pass-through.
    func filteredLemmaCandidates(forEdgeSurface edgeSurface: String) -> [String] {
        lemmaCandidatesForSurface(edgeSurface)
    }

    // Returns the string this row uses as its identity for save/star/tap
    // operations and dedup. With `showLemmasInSegmentList` on AND a non-empty
    // lemma available, returns the lemma; otherwise the raw edge surface.
    // The toggle controls behavior end-to-end via this single function.
    //
    // Reads through `lemmaCacheByEdgeSurface` first — populated off-main when
    // edges change (see `hydrateLemmasForEdgeSurfaces`) so flipping the lemma
    // toggle doesn't redo N segmenter trie + deinflector passes per render.
    // Cache miss falls through to the live segmenter call; that path is hit
    // during the brief warming window after edges change, then never again.
    func resolvedRowSurface(for edge: LatticeEdge) -> String {
        guard showLemmasInSegmentList else { return edge.surface }
        if let cached = lemmaCacheByEdgeSurface[edge.surface] {
            return cached.isEmpty ? edge.surface : cached
        }
        guard let lemma = lemmaForSurface(edge.surface), lemma.isEmpty == false else {
            return edge.surface
        }
        return lemma
    }

    // Cache-aware lemma lookup for the per-row body's `rowLemma`. Returns the
    // resolved lemma or empty string. Same hydration semantics as
    // `resolvedRowSurface` — uses the off-main-populated cache when available
    // so the toggle and scroll paths are O(1) per row.
    func cachedLemma(forEdgeSurface surface: String) -> String {
        if let cached = lemmaCacheByEdgeSurface[surface] {
            return cached
        }
        return (lemmaForSurface(surface) ?? "")
    }
}
