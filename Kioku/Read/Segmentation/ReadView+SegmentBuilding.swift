import SwiftUI
import UIKit

// Segment data utilities: edge application, range construction, persistence helpers, and furigana extraction.
extension ReadView {
    // Punctuation that the segmenter emits as standalone tokens. These were previously dropped
    // from the segment list as "noise", but doing so broke the concat-equals-content invariant
    // that load-time validation relies on — segments could no longer be restored from disk
    // because they didn't cover whitespace/punctuation in the source text. Now noise edges are
    // kept in the segment list, and noise filtering happens only at the lookup/tap layer via
    // shouldIgnoreSegmentForDefinitionLookup — taps on whitespace/punctuation still no-op.
    private static let noiseSegmentCharacters: Set<Character> = ["―", "？", "！", "?", "!"]

    // Returns true when the edge's surface is composed entirely of noise punctuation,
    // whitespace, or both. Used by tap handling to decline lookup on noise segments.
    static func isNoiseSegment(_ surface: String) -> Bool {
        guard surface.isEmpty == false else { return false }
        return surface.allSatisfy { c in
            c.isWhitespace || noiseSegmentCharacters.contains(c)
        }
    }

    // Rebuilds `self.segments` from the current `segmentEdges` and furigana maps, optionally
    // records a runtime snapshot, then persists the note. Single helper so the three places
    // that need "annotate the current edges with current furigana, then save" can't drift on
    // whether they remembered the runtime snapshot or the persist call.
    func rebuildAndPersistSegments(recordRuntime: Bool = false) {
        let rebuilt = buildSegmentRanges(
            from: segmentEdges,
            furiganaByLocation: furiganaBySegmentLocation,
            furiganaLengthByLocation: furiganaLengthBySegmentLocation
        )
        segments = rebuilt
        if recordRuntime {
            recordRuntimeSegmentationSnapshot(for: segmentEdges)
        }
        persistCurrentNoteIfNeeded()
    }

    // Applies active segmentation edges to UI state and refreshes furigana using those exact segment boundaries.
    func applySegmentEdges(_ edges: [LatticeEdge], persistOverride: Bool) {
        // A persisted override here is always a genuine user mutation — merge, split, or an
        // applied LLM correction (the only three callers). Mark the note edited so the reset
        // button reads as enabled; the load/reset paths clear this flag back to false.
        if persistOverride {
            hasManualSegmentationEdits = true
        }
        segmentEdges = edges
        segmentRanges = edges.map { edge in
            edge.start..<edge.end
        }
        // Manual edits (split/merge) intentionally produce surfaces that won't resolve in
        // the trie — the user just carved them. Computing unknownSegmentLocations here
        // would mark every fresh fragment as "unknown," and with Highlight Unknown on the
        // renderer would paint them all in `unknownSegmentColor` (= .label, invisible
        // against the base text). That manifests to the user as "all segment colors went
        // away after the split." Mirror refreshSegmentationRanges' fast path here and let
        // the next full segmenter pass repopulate unknowns from real lookup misses.
        unknownSegmentLocations = []
        recordRuntimeSegmentationSnapshot(for: edges)

        let pruned = pruneFuriganaForSegmentation(
            furiganaByLocation: furiganaBySegmentLocation,
            furiganaLengthByLocation: furiganaLengthBySegmentLocation,
            edges: edges,
            sourceText: text
        )
        furiganaBySegmentLocation = pruned.byLocation
        furiganaLengthBySegmentLocation = pruned.lengthByLocation

        if persistOverride {
            // Persist with the in-memory furigana embedded so the synchronous disk write
            // already carries every reading override that survived the segment-structure
            // change. The async regen below will fill defaults for any newly-blank segment.
            rebuildAndPersistSegments()
        }

        // Regenerate readings for newly-introduced segments (merge produced a new combined
        // surface, split produced segments without their own annotations). The compute pass
        // backfills missing entries without overwriting existing ones, so user overrides
        // and already-correct annotations stay put while gaps get filled.
        scheduleFuriganaGeneration(for: text, edges: edges)
    }

    // Marks the UTF-16 start locations of segments that do not resolve through the dictionary pipeline.
    func unknownSegmentLocations(for edges: [LatticeEdge]) -> Set<Int> {
        var unknownLocations: Set<Int> = []

        for edge in edges {
            let nsRange = NSRange(edge.start..<edge.end, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else {
                continue
            }

            if segmenter.resolvesSurface(edge.surface) == false {
                unknownLocations.insert(nsRange.location)
            }
        }

        return unknownLocations
    }

    // Converts segment edges to persistable order-only segment ranges for note persistence.
    // When furigana maps are provided, each segment is annotated with its resolved readings
    // using offsets relative to the segment's surface.
    //
    // `sourceText` defaults to ReadView's `text` @State so existing call sites compile
    // unchanged. Tests pass it explicitly because Swift String indices have identity to a
    // specific string — using indices from one string against another (the default empty
    // `text`) crashes with a Swift runtime trap instead of returning NSNotFound.
    func buildSegmentRanges(
        from edges: [LatticeEdge],
        in sourceText: String? = nil,
        furiganaByLocation: [Int: String] = [:],
        furiganaLengthByLocation: [Int: Int] = [:]
    ) -> [SegmentRange] {
        SegmentRange.ranges(
            from: edges,
            in: sourceText ?? text,
            furiganaByLocation: furiganaByLocation,
            furiganaLengthByLocation: furiganaLengthByLocation
        )
    }

    // Rebuilds segmentation edges from persisted order-only segments by walking the source
    // text with a cursor equal to the cumulative UTF-16 surface length.
    // Returns nil if concatenated surfaces do not match the source text exactly.
    func edgesFromSegmentRanges(_ segments: [SegmentRange], in sourceText: String) -> [LatticeEdge]? {
        let utf16View = sourceText.utf16
        let utf16TotalLength = utf16View.count
        guard utf16TotalLength > 0, segments.isEmpty == false else {
            return nil
        }

        var rebuiltEdges: [LatticeEdge] = []
        rebuiltEdges.reserveCapacity(segments.count)
        // Walk ONE index forward by each segment's UTF-16 length. Advancing within the UTF-16 view is
        // O(length), so the whole pass is O(n). The previous code recomputed
        // String.Index(utf16Offset:in:) from the string start each iteration — O(offset) per call,
        // O(n²) overall — which blocked the main thread on large notes' synchronous fast-path restore.
        var startIndex = sourceText.startIndex
        var consumed = 0
        for segmentRange in segments {
            let surfaceLength = segmentRange.surface.utf16.count
            guard surfaceLength > 0 else { continue }
            guard consumed + surfaceLength <= utf16TotalLength,
                  let endIndex = utf16View.index(startIndex, offsetBy: surfaceLength, limitedBy: sourceText.endIndex),
                  startIndex < endIndex else {
                return nil
            }

            let actualSurface = String(sourceText[startIndex..<endIndex])
            guard actualSurface == segmentRange.surface else { return nil }

            rebuiltEdges.append(
                LatticeEdge(
                    start: startIndex,
                    end: endIndex,
                    surface: actualSurface
                )
            )
            startIndex = endIndex
            consumed += surfaceLength
        }

        guard consumed == utf16TotalLength else { return nil }
        return rebuiltEdges.isEmpty ? nil : rebuiltEdges
    }

    // Resolves the canonical dictionary entry for the given surface in the background and records it in history.
    // Skips surfaces that are boundary characters, whitespace, or single-character kana-only tokens.
    func recordLookupHistory(surface: String) {
        let trimmed = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        guard ScriptClassifier.containsKanji(trimmed) || (ScriptClassifier.isPureKana(trimmed) && trimmed.count > 1) else { return }

        let candidates = orderedLookupCandidates(surface: trimmed, lemma: segmenter.preferredLemma(for: trimmed))
        let store = dictionaryStore
        // Pre-compute modes on the main actor before entering the detached task.
        let candidateModes: [(String, LookupMode)] = candidates.map {
            ($0, ScriptClassifier.containsKanji($0) ? .kanjiAndKana : .kanaOnly)
        }

        Task.detached(priority: .background) {
            for (candidate, mode) in candidateModes {
                if let entry = try? await MainActor.run(body: { try store?.lookup(surface: candidate, mode: mode) })?.first {
                    await MainActor.run {
                        historyStore.record(canonicalEntryID: entry.entryId, surface: trimmed)
                    }
                    return
                }
            }
        }
    }

    // Validates persisted order-only segments: concatenated surfaces must equal the source text.
    // Empty or mismatched inputs return nil, signaling the segmenter should recompute from scratch.
    func normalizedSegmentRanges(_ segments: [SegmentRange]?, for sourceText: String) -> [SegmentRange]? {
        guard let segments, segments.isEmpty == false else { return nil }

        let utf16TotalLength = sourceText.utf16.count
        guard utf16TotalLength > 0 else { return nil }

        // Drop empty-surface entries while checking that remaining surfaces concatenate to source.
        let filtered = segments.filter { $0.surface.isEmpty == false }
        guard filtered.isEmpty == false else { return nil }

        // Walk one index forward per segment (O(n) total) rather than recomputing a UTF-16 offset
        // index from the string start each iteration (O(n²)) — the latter stalled the synchronous
        // fast-path load on large notes.
        let utf16View = sourceText.utf16
        var startIndex = sourceText.startIndex
        var consumed = 0
        for segmentRange in filtered {
            let surfaceLength = segmentRange.surface.utf16.count
            guard consumed + surfaceLength <= utf16TotalLength,
                  let endIndex = utf16View.index(startIndex, offsetBy: surfaceLength, limitedBy: sourceText.endIndex),
                  startIndex < endIndex,
                  String(sourceText[startIndex..<endIndex]) == segmentRange.surface else {
                return nil
            }
            startIndex = endIndex
            consumed += surfaceLength
        }
        guard consumed == utf16TotalLength else { return nil }

        return filtered
    }

    // Reconciles existing persisted segments against an updated note content by keeping the
    // longest leading run of segments whose surfaces match a prefix of newContent, the longest
    // trailing run whose surfaces match a suffix, and collapsing the diverging middle into a
    // single stub segment. This preserves user splits/merges/furigana for every segment outside
    // the edited region. Returns nil when newContent is empty.
    func reconcileSegments(_ existing: [SegmentRange], to newContent: String) -> [SegmentRange]? {
        let newUTF16 = newContent.utf16.count
        guard newUTF16 > 0 else { return nil }

        let lengths = existing.map { $0.surface.utf16.count }

        // Walk from the front: accept each segment whose surface matches the corresponding
        // UTF-16 slice of newContent starting at the current prefix cursor.
        var prefixCount = 0
        var prefixOffset = 0
        for (index, segment) in existing.enumerated() {
            let length = lengths[index]
            guard length > 0, prefixOffset + length <= newUTF16 else { break }
            let startIndex = String.Index(utf16Offset: prefixOffset, in: newContent)
            let endIndex = String.Index(utf16Offset: prefixOffset + length, in: newContent)
            guard startIndex < endIndex,
                  String(newContent[startIndex..<endIndex]) == segment.surface else { break }
            prefixCount += 1
            prefixOffset += length
        }

        // If the entire existing array already matches new content exactly, pass through.
        if prefixCount == existing.count, prefixOffset == newUTF16 {
            return existing
        }

        // Walk from the back, halting before prefixCount so prefix and suffix cannot overlap.
        var suffixCount = 0
        var suffixStartInNew = newUTF16
        var i = existing.count - 1
        while i >= prefixCount {
            let length = lengths[i]
            let startOffset = suffixStartInNew - length
            guard length > 0, startOffset >= prefixOffset else { break }
            let startIndex = String.Index(utf16Offset: startOffset, in: newContent)
            let endIndex = String.Index(utf16Offset: suffixStartInNew, in: newContent)
            guard startIndex < endIndex,
                  String(newContent[startIndex..<endIndex]) == existing[i].surface else { break }
            suffixCount += 1
            suffixStartInNew = startOffset
            i -= 1
        }

        var reconciled: [SegmentRange] = []
        reconciled.append(contentsOf: existing.prefix(prefixCount))
        if suffixStartInNew > prefixOffset {
            let startIndex = String.Index(utf16Offset: prefixOffset, in: newContent)
            let endIndex = String.Index(utf16Offset: suffixStartInNew, in: newContent)
            let middleSurface = String(newContent[startIndex..<endIndex])
            // Retokenize the diverging middle in isolation so newly-typed text still gets
            // lattice-based segmentation; customizations on either side remain pinned by the
            // surrounding preserved segments. Context-sensitive merges across the splice are
            // intentionally suppressed — neighbors are user-customized and must not shift.
            let middleSegments = tokenizeSurfaceForReconcile(middleSurface)
            reconciled.append(contentsOf: middleSegments)
        }
        reconciled.append(contentsOf: existing.suffix(suffixCount))

        return reconciled.isEmpty ? nil : reconciled
    }

    // Runs the active segmenter against a substring and maps the resulting edges into
    // order-only segment ranges. Falls back to a single-segment wrapper when the segmenter
    // yields nothing usable (e.g. resources not ready), so concat-equals-content still holds.
    private func tokenizeSurfaceForReconcile(_ surface: String) -> [SegmentRange] {
        guard surface.isEmpty == false else { return [] }
        let edges = segmenter.longestMatchEdges(for: surface)
        guard edges.isEmpty == false else {
            return [SegmentRange(surface: surface)]
        }

        let produced = edges.map { SegmentRange(surface: $0.surface) }
        // Guard against a segmenter that fails to cover the full substring — preserve the
        // original surface as one segment rather than corrupt the concat invariant.
        guard produced.map(\.surface).joined() == surface else {
            return [SegmentRange(surface: surface)]
        }
        return produced
    }

    // Resolves segmentation edges to (UTF-16 NSRange, surface) pairs in sourceText, skipping
    // edges that don't round-trip to a valid NSRange. Shared by pruneFuriganaForSegmentation
    // and the furigana helpers that walk the same edge list — keeps the NSRange/String.Index
    // boundary math in one place.
    func segmentNSRangesAndSurfaces(
        for edges: [LatticeEdge],
        in sourceText: String
    ) -> [(range: NSRange, surface: String)] {
        edges.compactMap { edge in
            let range = NSRange(edge.start..<edge.end, in: sourceText)
            guard range.location != NSNotFound else { return nil }
            return (range: range, surface: edge.surface)
        }
    }

    // Drops furigana entries whose UTF-16 range no longer fits inside any segment. This is the
    // gentle structural prune used after splits — a wide entry spanning the pre-split surface
    // (e.g. ものがたり at [0, 2) over the pre-split 物語) does not fit any narrower successor
    // segment and is dropped here. Entries that DO fit inside their segment are kept, even if
    // they fragment a kanji run — replace-on-overlap backfill collapses those into a single
    // span when the recompute produces a wider compound reading, and synthesizeCompoundReadings
    // concatenates them when the recompute has no compound reading to offer.
    func pruneFuriganaForSegmentation(
        furiganaByLocation: [Int: String],
        furiganaLengthByLocation: [Int: Int],
        edges: [LatticeEdge],
        sourceText: String
    ) -> (byLocation: [Int: String], lengthByLocation: [Int: Int]) {
        let validRanges = segmentNSRangesAndSurfaces(for: edges, in: sourceText).map(\.range)

        var prunedByLocation = furiganaByLocation
        var prunedLengthByLocation = furiganaLengthByLocation
        for location in furiganaByLocation.keys {
            guard let length = furiganaLengthByLocation[location] else {
                // No matching length entry means the maps drifted apart (corrupted persisted
                // data or producer bug). Drop the orphan reading and warn.
                print("pruneFuriganaForSegmentation: missing length for entry at location \(location); dropping")
                prunedByLocation.removeValue(forKey: location)
                continue
            }
            guard length > 0 else {
                print("pruneFuriganaForSegmentation: zero-length entry at location \(location); dropping")
                prunedByLocation.removeValue(forKey: location)
                prunedLengthByLocation.removeValue(forKey: location)
                continue
            }
            let entryEnd = location + length
            let isInsideAnySegment = validRanges.contains { range in
                location >= range.location && entryEnd <= range.location + range.length
            }
            if isInsideAnySegment == false {
                prunedByLocation.removeValue(forKey: location)
                prunedLengthByLocation.removeValue(forKey: location)
            }
        }
        return (byLocation: prunedByLocation, lengthByLocation: prunedLengthByLocation)
    }

    // Extracts absolute-offset furigana maps from persisted order-only segments by walking
    // the surface cursor. Annotations are stored segment-relative and rebased here.
    func furiganaFromSegmentRanges(_ segments: [SegmentRange]) -> (byLocation: [Int: String], lengthByLocation: [Int: Int]) {
        var byLocation: [Int: String] = [:]
        var lengthByLocation: [Int: Int] = [:]
        var cursor = 0
        for segment in segments {
            let surfaceLength = segment.surface.utf16.count
            if let annotations = segment.furigana {
                for annotation in annotations {
                    let absoluteStart = cursor + annotation.start
                    let length = annotation.end - annotation.start
                    guard length > 0 else { continue }
                    byLocation[absoluteStart] = annotation.reading
                    lengthByLocation[absoluteStart] = length
                }
            }
            cursor += surfaceLength
        }
        return (byLocation: byLocation, lengthByLocation: lengthByLocation)
    }
}
