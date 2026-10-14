import Foundation

// The Read tab's resolved analysis of a note — its segments (including the user's splits and
// merges) and readings (including pinned corrections) — handed to the breakdown so its lines
// show exactly what the page shows instead of re-segmenting each line on its own.
struct NoteReadingSnapshot: Equatable {
    let text: String
    let segmentRanges: [Range<String.Index>]
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]

    // True when the snapshot describes `noteText` and carries any analysis at all — an empty
    // one (the Read tab hadn't finished segmenting) or one for other text can't be sliced.
    func isUsable(for noteText: String) -> Bool {
        text == noteText && segmentRanges.isEmpty == false
    }

    // Cuts the analysis down to `range` (a line of the note), rebased to the line's own
    // coordinates: segments clipped to the line, readings whose span lies inside it.
    func slice(_ range: NSRange) -> LineFuriganaCache? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        let lineText = String(text[swiftRange])
        let lineEnd = range.location + range.length
        var segments: [Range<String.Index>] = []
        for segment in segmentRanges {
            let ns = NSRange(segment, in: text)
            let start = max(ns.location, range.location)
            let end = min(ns.location + ns.length, lineEnd)
            guard end > start else { continue }
            segments.append(
                String.Index(utf16Offset: start - range.location, in: lineText)
                    ..< String.Index(utf16Offset: end - range.location, in: lineText)
            )
        }
        var byLocation: [Int: String] = [:]
        var lengthByLocation: [Int: Int] = [:]
        for (location, reading) in furiganaBySegmentLocation where location >= range.location && location < lineEnd {
            let length = furiganaLengthBySegmentLocation[location] ?? 0
            guard location + length <= lineEnd else { continue }
            byLocation[location - range.location] = reading
            lengthByLocation[location - range.location] = length
        }
        return LineFuriganaCache(
            sourceText: lineText,
            segmentationRanges: segments,
            furiganaBySegmentLocation: byLocation,
            furiganaLengthBySegmentLocation: lengthByLocation
        )
    }
}
