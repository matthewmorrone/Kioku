import Foundation

// Validates segment arrays before they're committed to a note, so the bridge
// surfaces a clear error rather than persisting state that violates the
// "concatenated surfaces equal content" invariant the rest of the app depends on.
enum BridgeSegmentValidator {
    // Returns a structured response on validation failure, or nil when the
    // proposed segments are admissible for the supplied content. Empty content
    // requires an empty segment array; non-empty content requires the
    // surfaces to concatenate exactly to the note text.
    static func validateConcatenation(
        segments: [BridgeSegment],
        content: String
    ) -> BridgeHTTPResponse? {
        let concatenated = segments.map(\.surface).joined()
        guard concatenated == content else {
            return .error(
                status: 422,
                code: "segment_concat_mismatch",
                message: "concatenated segment surfaces do not equal note content"
            )
        }

        for (index, segment) in segments.enumerated() {
            if let response = validateFurigana(segment.furigana, segmentSurface: segment.surface, segmentIndex: index) {
                return response
            }
        }
        return nil
    }

    // Validates a single segment's furigana run array. Used both by the segments
    // replace handler and by the standalone furigana replace handler.
    static func validateFurigana(
        _ annotations: [BridgeFurigana]?,
        segmentSurface: String,
        segmentIndex: Int
    ) -> BridgeHTTPResponse? {
        guard let annotations, annotations.isEmpty == false else { return nil }

        let surfaceLength = segmentSurface.utf16.count
        var previousEnd = -1

        for (annotationIndex, run) in annotations.enumerated() {
            if run.start < 0 || run.end > surfaceLength || run.end <= run.start {
                return .error(
                    status: 422,
                    code: "furigana_out_of_bounds",
                    message: "segment \(segmentIndex) furigana[\(annotationIndex)] [\(run.start), \(run.end)) is out of bounds for surface length \(surfaceLength)"
                )
            }
            if run.start < previousEnd {
                return .error(
                    status: 422,
                    code: "furigana_overlap",
                    message: "segment \(segmentIndex) furigana[\(annotationIndex)] overlaps the previous run"
                )
            }
            if run.reading.isEmpty {
                return .error(
                    status: 422,
                    code: "furigana_empty_reading",
                    message: "segment \(segmentIndex) furigana[\(annotationIndex)] reading is empty"
                )
            }
            previousEnd = run.end
        }
        return nil
    }
}
