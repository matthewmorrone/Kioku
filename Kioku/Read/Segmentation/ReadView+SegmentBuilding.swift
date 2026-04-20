import SwiftUI
import UIKit

// Segment data utilities: edge application, range construction, persistence helpers, and furigana extraction.
extension ReadView {
    // Applies active segmentation edges to UI state and refreshes furigana using those exact segment boundaries.
    func applySegmentEdges(_ edges: [LatticeEdge], persistOverride: Bool) {
        segmentEdges = edges
        segmentRanges = edges.map { edge in
            edge.start..<edge.end
        }
        unknownSegmentLocations = unknownSegmentLocations(for: edges)
        recordRuntimeSegmentationSnapshot(for: edges)

        // Remove furigana entries whose location no longer aligns with a valid segment boundary.
        // Stale entries arise when a segment is split or merged — the old location becomes invalid.
        let validLocations = Set(edges.compactMap { edge -> Int? in
            let r = NSRange(edge.start..<edge.end, in: text)
            return r.location != NSNotFound ? r.location : nil
        })
        for location in Array(furiganaBySegmentLocation.keys) {
            if validLocations.contains(location) == false {
                furiganaBySegmentLocation.removeValue(forKey: location)
                furiganaLengthBySegmentLocation.removeValue(forKey: location)
            }
        }

        if persistOverride {
            let segments = buildSegmentRanges(from: edges)
            self.segments = segments
            persistCurrentNoteIfNeeded()
        }

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
    func buildSegmentRanges(
        from edges: [LatticeEdge],
        furiganaByLocation: [Int: String] = [:],
        furiganaLengthByLocation: [Int: Int] = [:]
    ) -> [SegmentRange] {
        edges.compactMap { edge in
            let nsRange = NSRange(edge.start..<edge.end, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else {
                return nil
            }

            // Collect all furigana annotations whose absolute range falls within this segment,
            // then rebase them to surface-relative offsets.
            let segStart = nsRange.location
            let segEnd = nsRange.location + nsRange.length
            let annotations: [FuriganaAnnotation] = furiganaByLocation.compactMap { location, reading in
                guard let length = furiganaLengthByLocation[location],
                      location >= segStart, location + length <= segEnd else { return nil }
                let relativeStart = location - segStart
                return FuriganaAnnotation(start: relativeStart, end: relativeStart + length, reading: reading)
            }.sorted { $0.start < $1.start }

            return SegmentRange(
                surface: edge.surface,
                furigana: annotations.isEmpty ? nil : annotations
            )
        }
    }

    // Rebuilds segmentation edges from persisted order-only segments by walking the source
    // text with a cursor equal to the cumulative UTF-16 surface length.
    // Returns nil if concatenated surfaces do not match the source text exactly.
    func edgesFromSegmentRanges(_ segments: [SegmentRange], in sourceText: String) -> [LatticeEdge]? {
        let utf16TotalLength = sourceText.utf16.count
        guard utf16TotalLength > 0, segments.isEmpty == false else {
            return nil
        }

        var rebuiltEdges: [LatticeEdge] = []
        var cursor = 0
        for segmentRange in segments {
            let surfaceLength = segmentRange.surface.utf16.count
            guard surfaceLength > 0 else { continue }
            let startOffset = cursor
            let endOffset = cursor + surfaceLength
            guard endOffset <= utf16TotalLength else { return nil }

            let startIndex = String.Index(utf16Offset: startOffset, in: sourceText)
            let endIndex = String.Index(utf16Offset: endOffset, in: sourceText)
            guard startIndex < endIndex else { return nil }

            let actualSurface = String(sourceText[startIndex..<endIndex])
            guard actualSurface == segmentRange.surface else { return nil }

            rebuiltEdges.append(
                LatticeEdge(
                    start: startIndex,
                    end: endIndex,
                    surface: actualSurface
                )
            )
            cursor = endOffset
        }

        guard cursor == utf16TotalLength else { return nil }
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

        var cursor = 0
        for segmentRange in filtered {
            let surfaceLength = segmentRange.surface.utf16.count
            guard cursor + surfaceLength <= utf16TotalLength else { return nil }
            let startIndex = String.Index(utf16Offset: cursor, in: sourceText)
            let endIndex = String.Index(utf16Offset: cursor + surfaceLength, in: sourceText)
            guard startIndex < endIndex,
                  String(sourceText[startIndex..<endIndex]) == segmentRange.surface else {
                return nil
            }
            cursor += surfaceLength
        }
        guard cursor == utf16TotalLength else { return nil }

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
