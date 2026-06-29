import Foundation

// Converts an LLMCorrectionResponse into the persisted [SegmentRange] shape
// without needing a live ReadView. Used by LLMCorrectionQueue so notes can
// have corrections applied in the background after a bulk import — i.e.
// before the user opens them. The view-bound apply path in
// ReadView+LLMCorrection still owns the per-note pending-changes UX; this
// utility just lands the corrected segmentation onto disk.
enum LLMCorrectionApplier {
    // Builds the [SegmentRange] list to persist on a note, or nil when the
    // response can't be reconciled with the note's content. Reconciliation
    // attempts the same whitespace repair the view uses, then requires the
    // concatenated surfaces to equal originalText exactly. Newline entries
    // ("\n" surfaces emitted between lines by the compact-format parser and
    // by AppleIntelligenceCorrectionClient) are kept — they're real surface
    // characters that must contribute to the concat check for multi-line
    // notes to match.
    static func segmentRanges(
        from response: LLMCorrectionResponse,
        originalText: String
    ) -> [SegmentRange]? {
        let working = reconcileEntries(response.segments, against: originalText)
            ?? response.segments

        let contentEntries = working.filter { entry in
            entry.surface.isEmpty == false
        }
        guard contentEntries.isEmpty == false else { return nil }

        // Concat check — every character must be accounted for, in order,
        // including newline separators between lines.
        let concatenated = contentEntries.map(\.surface).joined()
        guard concatenated == originalText else { return nil }

        return contentEntries.map { entry in
            makeSegmentRange(surface: entry.surface, reading: entry.reading)
        }
    }

    // Attempts the whitespace-tolerant repair before failing. Returns nil when
    // the response already concatenates cleanly so the caller doesn't waste
    // work on a no-op repair. Newline entries are kept in the concat check
    // for the same reason segmentRanges keeps them — they're literal surface
    // characters in multi-line content.
    private static func reconcileEntries(
        _ entries: [LLMSegmentEntry],
        against originalText: String
    ) -> [LLMSegmentEntry]? {
        let content = entries.filter { $0.surface.isEmpty == false }
        if content.map(\.surface).joined() == originalText {
            return entries
        }
        return LLMCorrectionDiagnostics.repairWhitespaceMismatches(entries, against: originalText)
    }

    // Builds one SegmentRange with per-kanji-run FuriganaAnnotation entries.
    // Falls back to a single whole-surface annotation when projection can't
    // align the reading against okurigana — same fallback ReadView uses.
    // Pure-kana / punctuation / whitespace segments get no annotations.
    private static func makeSegmentRange(surface: String, reading: String) -> SegmentRange {
        guard reading.isEmpty == false else {
            return SegmentRange(surface: surface)
        }
        let runs = FuriganaAttributedString.kanjiRuns(in: surface)
        guard runs.isEmpty == false else {
            return SegmentRange(surface: surface)
        }
        if let perRun = FuriganaAttributedString.projectRunReadings(surface: surface, reading: reading, runs: runs),
           perRun.count == runs.count {
            let chars = Array(surface)
            var annotations: [FuriganaAnnotation] = []
            annotations.reserveCapacity(perRun.count)
            for (index, run) in runs.enumerated() {
                let prefix = String(chars[0..<run.start])
                let segment = String(chars[run.start..<run.end])
                let startUTF16 = prefix.utf16.count
                let endUTF16 = startUTF16 + segment.utf16.count
                annotations.append(FuriganaAnnotation(
                    start: startUTF16,
                    end: endUTF16,
                    reading: perRun[index]
                ))
            }
            return SegmentRange(surface: surface, furigana: annotations)
        }
        // Whole-surface fallback — ReadView's apply path also tolerates this
        // for surfaces with kanji runs whose okurigana doesn't anchor cleanly.
        let utf16Len = surface.utf16.count
        return SegmentRange(
            surface: surface,
            furigana: [FuriganaAnnotation(start: 0, end: utf16Len, reading: reading)]
        )
    }
}
