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
    nonisolated static func resolveParsedSegments(
        tokens: [String],
        store: DictionaryStore
    ) -> [ParsedSegment] {
        // Cache repeated surfaces (の, は, etc.) so a long sentence doesn't fan out
        // into one SQLite round-trip per occurrence.
        var cache: [String: DictionaryEntry?] = [:]
        return tokens.map { surface in
            if let cached = cache[surface] {
                return ParsedSegment(surface: surface, entry: cached)
            }
            let hit = dictionaryTop(store: store, surface: surface)
            cache[surface] = hit
            return ParsedSegment(surface: surface, entry: hit)
        }
    }

    // Top dictionary hit for `surface`, or nil if the dictionary has no entry for it.
    private nonisolated static func dictionaryTop(store: DictionaryStore, surface: String) -> DictionaryEntry? {
        let hits = (try? store.searchEntries(term: surface, mode: .japanese, limit: 1)) ?? []
        return hits.first
    }
}
