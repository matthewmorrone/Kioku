import SwiftUI

// One row of a Pleco-style sentence parse. `entry` is the segment's top dictionary
// hit (nil when the segmenter produced a surface that the dictionary doesn't index —
// proper nouns, unknown kana clusters, deinflected forms with no headword).
struct ParsedSegment: Identifiable {
    let id = UUID()
    let surface: String
    let entry: DictionaryEntry?
}

extension WordsView {
    // MARK: - Parsed-rows view

    // Drop-in replacement for the entry-list section when sentence-parse mode is active.
    // The filters section above it still renders; segments aren't subject to common-word /
    // POS / sort filters since their order comes from the original text.
    @ViewBuilder
    var parsedSegmentsResultsSection: some View {
        Section {
            ForEach(parsedSegments) { segment in
                parsedSegmentRow(segment)
            }
        } header: {
            Text("\(parsedSegments.count) Segment\(parsedSegments.count == 1 ? "" : "s")")
        }
    }

    // Renders one parsed segment.
    //
    // Unlike DictionarySearchResultRow, this row displays the *segment surface* as the headline —
    // the thing the user actually typed. We must NOT delegate to entry.primarySearchSurface,
    // because for particles like の that returns a sK-tagged archaic kanji form (乃) instead of the
    // kana the user typed. Reading is shown only when the surface contains kanji.
    @ViewBuilder
    private func parsedSegmentRow(_ segment: ParsedSegment) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(segment.surface)
                        .font(.headline)
                    if let reading = parsedSegmentReading(for: segment) {
                        Text(reading)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let gloss = parsedSegmentGloss(for: segment), gloss.isEmpty == false {
                    Text(gloss)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if let entry = segment.entry {
                Button {
                    toggleSave(entry)
                } label: {
                    let saved = isSaved(entry)
                    Image(systemName: saved ? "star.fill" : "star")
                        .foregroundStyle(saved ? Color.yellow : Color.secondary)
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSaved(entry) ? "Unsave Word" : "Save Word")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if let entry = segment.entry {
                openSearchResult(entry)
            }
        }
    }

    // Reading shown next to the surface — only when the segment surface contains kanji.
    // Pure-kana segments would be repeating themselves; suppressing the reading keeps rows
    // visually tight for sentence parses dominated by particles and inflections.
    private func parsedSegmentReading(for segment: ParsedSegment) -> String? {
        guard ScriptClassifier.containsKanji(segment.surface),
              let entry = segment.entry,
              let reading = entry.kanaForms.first?.text,
              reading.isEmpty == false,
              reading != segment.surface else {
            return nil
        }
        return reading
    }

    // Compact "[pos] gloss" label, matching DictionarySearchResultRow's primaryGloss shape.
    private func parsedSegmentGloss(for segment: ParsedSegment) -> String? {
        guard let entry = segment.entry,
              let sense = entry.senses.first else { return nil }
        var parts: [String] = []
        if let pos = sense.pos, pos.isEmpty == false {
            parts.append("[\(JMdictTagExpander.expand(pos))]")
        }
        if let gloss = sense.glosses.first, gloss.isEmpty == false {
            parts.append(gloss)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Segmentation

    // Runs the shared MeCab/Viterbi segmenter over `text` and returns its non-boundary tokens.
    // Returns an empty array when the segmenter is unavailable or the query is degenerate so
    // the caller can fall back to literal entry-search.
    nonisolated static func parseTokens(_ text: String, using segmenter: (any TextSegmenting)?) -> [String] {
        guard let segmenter else { return [] }
        let edges = segmenter.longestMatchEdges(for: text)
        let boundary = Segmenter.boundaryCharacters
        return edges.compactMap { edge -> String? in
            let surface = edge.surface
            guard surface.isEmpty == false else { return nil }
            if surface.count == 1, let only = surface.first, boundary.contains(only) {
                return nil
            }
            return surface
        }
    }

    // Resolves each segment surface to its best dictionary hit. Runs off-main; safe to call
    // from a detached task. Returns segments in their original order.
    //
    // Implementation:
    //   1. Look up each unique surface's canonical entry id via the in-memory map
    //      (O(1) per surface — populated at startup by populateCanonicalEntryIDMap).
    //   2. Materialize all needed entries in ONE batched SQL call.
    //   3. Build the per-token result by joining back to the materialized table.
    //
    // Falls back to dictionaryTop (per-token searchEntries fan-out) for surfaces missing
    // from the canonical map, which happens before the prewarming pass finishes during
    // the first few seconds after launch.
    nonisolated static func resolveParsedSegments(
        tokens: [String],
        store: DictionaryStore
    ) -> [ParsedSegment] {
        // Collect each unique surface's canonical entry id (skip nils — those will fall
        // back to dictionaryTop below).
        var canonicalIDBySurface: [String: Int64] = [:]
        var fallbackSurfaces: Set<String> = []
        for surface in Set(tokens) {
            if let entryID = store.lookupFirstEntryID(surface: surface) {
                canonicalIDBySurface[surface] = entryID
            } else {
                fallbackSurfaces.insert(surface)
            }
        }

        // One batched SQL roundtrip for every entry id we found via the canonical map.
        let entryIDs = Array(Set(canonicalIDBySurface.values))
        let batched = (try? store.lookupEntries(entryIDs: entryIDs)) ?? []
        let entryByID = Dictionary(uniqueKeysWithValues: batched.map { ($0.entryId, $0) })

        // Fallback: per-surface dictionaryTop for anything the canonical map didn't cover.
        var fallbackBySurface: [String: DictionaryEntry?] = [:]
        for surface in fallbackSurfaces {
            fallbackBySurface[surface] = dictionaryTop(store: store, surface: surface)
        }

        return tokens.map { surface in
            if let entryID = canonicalIDBySurface[surface], let entry = entryByID[entryID] {
                return ParsedSegment(surface: surface, entry: entry)
            }
            if let fallback = fallbackBySurface[surface] {
                return ParsedSegment(surface: surface, entry: fallback)
            }
            return ParsedSegment(surface: surface, entry: nil)
        }
    }

    // Top dictionary hit for `surface`, or nil if the dictionary has no entry for it.
    //
    // Pulls the top 5 hits from the existing search ranking, then applies a sense-breadth
    // tiebreak among entries whose JPDB rank is within ~5× of the best entry's rank
    // (or all rank-less). This fixes cases where JPDB's anime/VN corpus elevates a narrow
    // homograph above the broader canonical entry — e.g. 瞬く resolves to entry 172123
    // (しばたたく, 1 sense "to blink repeatedly") because JPDB ranks it 8634 vs entry 31593
    // (またたく, 2 senses "to twinkle / to blink") at 10603. They're close in rank but the
    // broader entry is the one a learner expects to see first.
    //
    // Outside the tolerance band, JPDB rank wins as before — we don't want to override
    // cases where there's a clear frequency-based winner.
    private nonisolated static func dictionaryTop(store: DictionaryStore, surface: String) -> DictionaryEntry? {
        let hits = (try? store.searchEntries(term: surface, mode: .japanese, limit: 5)) ?? []
        guard let first = hits.first else { return nil }
        // Cluster: hits whose JPDB rank is within the tolerance band of the top hit.
        // Rank-less entries cluster together (both nil); a rank-less hit doesn't cluster
        // with a ranked one because we have no scale to compare them.
        let tolerance = 5.0
        let cluster = hits.prefix(5).filter { entry in
            switch (first.jpdbRank, entry.jpdbRank) {
            case (nil, nil): return true
            case let (.some(top), .some(other)): return Double(other) <= Double(top) * tolerance
            default: return false
            }
        }
        // Within the cluster, prefer the entry with the most senses (broader coverage).
        // Stable on ties — preserves JPDB order among entries with equal sense counts.
        return cluster.enumerated().max { lhs, rhs in
            if lhs.element.senses.count != rhs.element.senses.count {
                return lhs.element.senses.count < rhs.element.senses.count
            }
            return lhs.offset > rhs.offset
        }?.element ?? first
    }
}
