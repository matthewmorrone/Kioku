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
    // Returns the lemma candidates for `edgeSurface` filtered down to those
    // that could plausibly produce this surface — i.e. whose dictionary
    // entries have at least one verb or i-adjective sense. Only these POS
    // classes actually conjugate, so for past-tense / te-form / negative-form
    // surfaces the segmenter's mechanical deinflection emits noun candidates
    // (e.g. なつ for なった) that aren't real interpretations.
    //
    // The filter is bypassed when the segmenter's first pick equals the
    // surface itself — there's no deinflection happening so all POS classes
    // are legitimate (the user might have typed a noun like "本").
    //
    // Looked up via DictionaryStore at call time, which means each call costs
    // a few SQL lookups. Acceptable here because this only runs when the row
    // re-renders (rare) and only touches a handful of candidate strings.
    func filteredLemmaCandidates(forEdgeSurface edgeSurface: String) -> [String] {
        let candidates = lemmaCandidatesForSurface(edgeSurface)
        guard let store = dictionaryStore else { return candidates }
        let isDictionaryFormSurface = candidates.first == edgeSurface
        if isDictionaryFormSurface { return candidates }
        return candidates.filter { lemma in
            guard let entries = try? store.lookup(surface: lemma, mode: .kanjiAndKana),
                  entries.isEmpty == false else {
                return false
            }
            return entries.contains { entry in
                entry.senses.contains { sense in
                    let bits = PartOfSpeech.bits(from: sense.pos)
                    return PartOfSpeech.isVerb(bits) || PartOfSpeech.isAdjective(bits)
                }
            }
        }
    }

    // Returns the string this row uses as its identity for save/star/tap
    // operations and dedup. With `showLemmasInSegmentList` on AND a non-empty
    // lemma available, returns the lemma; otherwise the raw edge surface.
    // The toggle controls behavior end-to-end via this single function.
    func resolvedRowSurface(for edge: LatticeEdge) -> String {
        guard showLemmasInSegmentList,
              let lemma = lemmaForSurface(edge.surface),
              lemma.isEmpty == false else {
            return edge.surface
        }
        return lemma
    }
}
