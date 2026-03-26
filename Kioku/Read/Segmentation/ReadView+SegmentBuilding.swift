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

    // Converts segment edges to explicit UTF-16 segment ranges for note persistence.
    // When furigana maps are provided, each segment is annotated with its resolved readings.
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

            // Collect all furigana annotations whose range falls within this segment.
            let segStart = nsRange.location
            let segEnd = nsRange.location + nsRange.length
            let annotations: [FuriganaAnnotation] = furiganaByLocation.compactMap { location, reading in
                guard let length = furiganaLengthByLocation[location],
                      location >= segStart, location + length <= segEnd else { return nil }
                return FuriganaAnnotation(start: location, end: location + length, reading: reading)
            }.sorted { $0.start < $1.start }

            return SegmentRange(
                start: segStart,
                end: segEnd,
                surface: edge.surface,
                furigana: annotations.isEmpty ? nil : annotations
            )
        }
    }

    // Rebuilds segmentation edges from persisted UTF-16 segment ranges.
    func edgesFromSegmentRanges(_ segments: [SegmentRange], in sourceText: String) -> [LatticeEdge]? {
        let utf16TotalLength = sourceText.utf16.count
        guard utf16TotalLength > 0 else {
            return nil
        }

        var rebuiltEdges: [LatticeEdge] = []
        for segmentRange in segments {
            let startOffset = segmentRange.start
            let endOffset = segmentRange.end
            guard endOffset > startOffset else {
                continue
            }

            let startIndex = String.Index(utf16Offset: startOffset, in: sourceText)
            let endIndex = String.Index(utf16Offset: endOffset, in: sourceText)
            guard startIndex < endIndex else {
                continue
            }

            let surface = String(sourceText[startIndex..<endIndex])
            rebuiltEdges.append(
                LatticeEdge(
                    start: startIndex,
                    end: endIndex,
                    surface: surface
                )
            )
        }

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

    // Normalizes persisted segment ranges from a note so only valid ranges are applied.
    func normalizedSegmentRanges(_ segments: [SegmentRange]?, for sourceText: String) -> [SegmentRange]? {
        guard let segments else {
            return nil
        }

        let utf16TotalLength = sourceText.utf16.count
        guard utf16TotalLength > 0 else {
            return nil
        }

        let normalizedRanges = segments
            .filter { segmentRange in
                segmentRange.start >= 0
                    && segmentRange.end > segmentRange.start
                    && segmentRange.end <= utf16TotalLength
            }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start {
                    return lhs.start < rhs.start
                }
                return lhs.end < rhs.end
            }

        guard normalizedRanges.isEmpty == false else {
            return nil
        }

        // Require exact contiguous coverage of the full text to keep range persistence deterministic.
        var cursor = 0
        for segmentRange in normalizedRanges {
            guard segmentRange.start == cursor else {
                return nil
            }
            cursor = segmentRange.end
        }

        guard cursor == utf16TotalLength else {
            return nil
        }

        return normalizedRanges
    }

    // Extracts furigana annotation maps from persisted segment ranges for direct restoration on load.
    func furiganaFromSegmentRanges(_ segments: [SegmentRange]) -> (byLocation: [Int: String], lengthByLocation: [Int: Int]) {
        var byLocation: [Int: String] = [:]
        var lengthByLocation: [Int: Int] = [:]
        for segment in segments {
            guard let annotations = segment.furigana else { continue }
            for annotation in annotations {
                byLocation[annotation.start] = annotation.reading
                lengthByLocation[annotation.start] = annotation.end - annotation.start
            }
        }
        return (byLocation: byLocation, lengthByLocation: lengthByLocation)
    }
}
