import Foundation

// Pure restoration of a note's persisted order-only segments (`Note.segments`) into a UTF-16
// furigana map. Extracted out of ReadView so screens that don't own a ReadView instance (e.g.
// SongStepperView) can still restore the exact readings the user sees/pinned on the Read tab,
// rather than recomputing fresh defaults. ReadView's own instance methods of the same names
// (ReadView+SegmentBuilding.swift) delegate here so every existing call site is unaffected.
enum SegmentRangeRestoration {
    // Validates persisted order-only segments: concatenated surfaces must equal the source text.
    // Empty or mismatched inputs return nil, signaling the caller should recompute from scratch.
    static func normalizedSegmentRanges(_ segments: [SegmentRange]?, for sourceText: String) -> [SegmentRange]? {
        guard let segments, segments.isEmpty == false else { return nil }

        let utf16TotalLength = sourceText.utf16.count
        guard utf16TotalLength > 0 else { return nil }

        // Drop empty-surface entries while checking that remaining surfaces concatenate to source.
        let filtered = segments.filter { $0.surface.isEmpty == false }
        guard filtered.isEmpty == false else { return nil }

        // Walk one index forward per segment (O(n) total) rather than recomputing a UTF-16 offset
        // index from the string start each iteration (O(n²)).
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

    // Extracts absolute-offset furigana maps from persisted order-only segments by walking
    // the surface cursor. Annotations are stored segment-relative and rebased here.
    static func furiganaFromSegmentRanges(_ segments: [SegmentRange]) -> (byLocation: [Int: String], lengthByLocation: [Int: Int]) {
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
