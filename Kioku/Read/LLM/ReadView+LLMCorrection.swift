import SwiftUI

// Hosts LLM-driven segmentation and reading correction logic for the read screen.
// Converts current view state into a request payload, applies validated responses,
// and surfaces errors as alerts.
extension ReadView {

    // Builds the current segment + reading snapshot and sends it to the LLM for correction.
    // Shows the result inline — either applying changes or surfacing an error alert.
    func requestLLMCorrection() {
        guard llmCorrectionTask == nil else { return }

        let currentSegments = buildLLMSegmentEntries()
        guard currentSegments.isEmpty == false else {
            llmCorrectionErrorMessage = "No segments to correct. Make sure the note has content and segmentation has loaded."
            isShowingLLMCorrectionError = true
            return
        }

        let capturedText = text
        let compactSegments = buildCompactFormat(from: currentSegments)
        print("[LLM] Compact input:\n\(compactSegments)")
        let service = LLMCorrectionService()

        isRequestingLLMCorrection = true
        llmCorrectionTask = Task {
            defer {
                Task { @MainActor in
                    isRequestingLLMCorrection = false
                    llmCorrectionTask = nil
                }
            }

            do {
                let response = try await service.requestCorrections(
                    compactSegments: compactSegments
                )

                await MainActor.run {
                    let result = applyLLMCorrectionResponse(response, originalText: capturedText)
                    handleLLMCorrectionResult(result)
                }
            } catch {
                await MainActor.run {
                    llmCorrectionErrorMessage = error.localizedDescription
                    isShowingLLMCorrectionError = true
                }
            }
        }
    }

    // Cancels any in-flight LLM correction request.
    func cancelLLMCorrection() {
        llmCorrectionTask?.cancel()
        llmCorrectionTask = nil
        isRequestingLLMCorrection = false
    }

    // Converts the current segment edges and reading overrides into LLMSegmentEntry values
    // so the LLM can see both the segmentation boundaries and the furigana assigned to each.
    private func buildLLMSegmentEntries() -> [LLMSegmentEntry] {
        segmentEdges.compactMap { edge in
            let nsRange = NSRange(edge.start..<edge.end, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }

            // Prefer the persisted reading override; fall back to computed furigana.
            let reading = selectedReadingOverrideByLocation[nsRange.location]
                ?? furiganaBySegmentLocation[nsRange.location]
                ?? ""

            return LLMSegmentEntry(surface: edge.surface, reading: reading)
        }
    }

    // Validates the LLM response and applies it using the same normalizedSegmentRanges +
    // edgesFromSegmentRanges pipeline used when restoring a note from import.
    private func applyLLMCorrectionResponse(
        _ response: LLMCorrectionResponse,
        originalText: String
    ) -> LLMCorrectionResult {
        // Build UTF-16 SegmentRange values by walking the surfaces in order.
        // This matches how export/import encodes segments.
        var ranges: [SegmentRange] = []
        var utf16Cursor = 0

        for entry in response.segments {
            let utf16Length = entry.surface.utf16.count
            guard utf16Length > 0 else { continue }
            ranges.append(SegmentRange(start: utf16Cursor, end: utf16Cursor + utf16Length))
            utf16Cursor += utf16Length
        }

        // Run the same contiguous-coverage validation used by loadSelectedNoteIfNeeded.
        guard let validatedRanges = normalizedSegmentRanges(ranges, for: originalText) else {
            let reconstructed = response.segments.map(\.surface).joined()
            printMismatchReport(original: originalText, reconstructed: reconstructed, response: response)

            return .surfaceMismatch
        }

        // Rebuild LatticeEdge values from the validated UTF-16 ranges.
        guard let rebuiltEdges = edgesFromSegmentRanges(validatedRanges, in: originalText) else {
            print("[LLM] edgesFromSegmentRanges returned nil despite passing normalizedSegmentRanges")
            return .surfaceMismatch
        }

        // Snapshot old state before mutating anything so the diff is clean.
        let oldSurfaces = segmentEdges.map(\.surface)
        let oldFurigana = furiganaBySegmentLocation
        let newSurfaces = rebuiltEdges.map(\.surface)

        var diffLines: [String] = []

        // Boundary diff: align old and new surface lists and flag mismatches.
        if oldSurfaces != newSurfaces {
            let oldCompact = oldSurfaces.joined(separator: "|")
            let newCompact = newSurfaces.joined(separator: "|")
            diffLines.append("Boundaries:\n  − \(oldCompact)\n  + \(newCompact)")
        }

        // Apply the new edges as a persisted override, replacing any stale segmentation.
        applySegmentEdges(rebuiltEdges, persistOverride: true)

        // Pair rebuilt edges with response entries by index to apply readings.
        // Both arrays derive from the same source so counts should match;
        // zip truncates silently if they differ, which would skip tail entries.
        for (edge, entry) in zip(rebuiltEdges, response.segments) {
            let nsRange = NSRange(edge.start..<edge.end, in: originalText)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }

            let location = nsRange.location
            let length = nsRange.length

            if entry.reading.isEmpty {
                selectedReadingOverrideByLocation.removeValue(forKey: location)
                furiganaBySegmentLocation.removeValue(forKey: location)
                furiganaLengthBySegmentLocation.removeValue(forKey: location)
            } else {
                // Store the raw reading; scheduleFuriganaGeneration strips okurigana at display time.
                selectedReadingOverrideByLocation[location] = entry.reading
                furiganaBySegmentLocation[location] = entry.reading
                furiganaLengthBySegmentLocation[location] = length

                // Compare normalized display output against the pre-mutation snapshot so we aren't
                // fooled by full readings (たべる) vs already-stripped display values (た).
                let incoming = normalizedDisplayReadings(surface: edge.surface, reading: entry.reading, baseLocation: location)
                let existing = snapshotDisplayReadings(from: oldFurigana, for: edge.surface, baseLocation: location)
                if incoming != existing {
                    let oldReading = existing.values.sorted().joined(separator: "/")
                    let newReading = incoming.values.sorted().joined(separator: "/")
                    let oldStr = oldReading.isEmpty ? "—" : oldReading
                    diffLines.append("\(edge.surface): \(oldStr) → \(newReading)")
                }
            }
        }

        persistCurrentNoteIfNeeded()
        return .applied(diff: diffLines)
    }

    // Returns the per-run display readings that would result from applying a given reading to a surface,
    // keyed by UTF-16 location. Used to compare intended display output without being fooled by
    // differences between full readings (たべる) and already-stripped ones (た).
    private func normalizedDisplayReadings(surface: String, reading: String, baseLocation: Int) -> [Int: String] {
        let chars = Array(surface)
        let runs = kanjiRuns(in: surface)
        guard runs.isEmpty == false else { return [:] }

        if let runReadings = projectRunReadings(surface: surface, reading: reading),
           runReadings.count == runs.count {
            var result: [Int: String] = [:]
            for (run, runReading) in zip(runs, runReadings) {
                guard runReading.isEmpty == false else { continue }
                let prefixUTF16 = String(chars[..<run.start]).utf16.count
                result[baseLocation + prefixUTF16] = runReading
            }
            return result
        }

        return [baseLocation: reading]
    }

    // Extracts display readings from a pre-mutation furigana snapshot for comparison.
    private func snapshotDisplayReadings(from snapshot: [Int: String], for surface: String, baseLocation: Int) -> [Int: String] {
        let utf16Length = surface.utf16.count
        return snapshot.filter { loc, _ in
            loc >= baseLocation && loc < baseLocation + utf16Length
        }
    }

    // Emits a structured mismatch report so the divergence is immediately actionable.
    // Shows line/column, a side-by-side context window, and Unicode scalars of the
    // differing characters so invisible differences (spaces, newlines, surrogates) are visible.
    private func printMismatchReport(
        original: String,
        reconstructed: String,
        response: LLMCorrectionResponse
    ) {
        let origChars = Array(original)
        let reconChars = Array(reconstructed)

        // Compute line + column for a character index by scanning for newlines.
        func lineCol(in chars: [Character], at idx: Int) -> (line: Int, col: Int) {
            var line = 1
            var col = 1
            for i in 0..<min(idx, chars.count) {
                if chars[i] == "\n" { line += 1; col = 1 } else { col += 1 }
            }
            return (line, col)
        }

        // Unicode scalar dump for a character so invisible differences are visible.
        func scalars(_ c: Character) -> String {
            c.unicodeScalars.map { "U+\(String($0.value, radix: 16, uppercase: true))" }.joined(separator: " ")
        }

        print("[LLM] Mismatch — original \(original.utf16.count) UTF-16 units, reconstructed \(reconstructed.utf16.count)")

        if let idx = zip(origChars, reconChars).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            let (line, col) = lineCol(in: origChars, at: idx)
            let origChar = origChars[idx]
            let reconChar = reconChars[idx]
            print("[LLM] First difference at line \(line), col \(col):")
            print("       original : '\(origChar)'  \(scalars(origChar))")
            print("       response : '\(reconChar)'  \(scalars(reconChar))")

            // Side-by-side context: 3 lines centred on the divergence line, aligned.
            let origLines = original.components(separatedBy: "\n")
            let reconLines = reconstructed.components(separatedBy: "\n")
            let firstLine = max(1, line - 1)
            let lastLine  = min(max(origLines.count, reconLines.count), line + 1)
            print("[LLM] Context (line | original vs response):")
            for l in firstLine...lastLine {
                let o = l <= origLines.count ? origLines[l - 1] : "<missing>"
                let r = l <= reconLines.count ? reconLines[l - 1] : "<missing>"
                let marker = l == line ? ">>>" : "   "
                print("  \(marker) \(l) | orig: \(o)")
                print("  \(marker) \(l) | resp: \(r)")
            }
        } else {
            // Common prefix — difference is in the tail.
            let shorter = min(origChars.count, reconChars.count)
            let origTail = origChars.dropFirst(shorter)
            let reconTail = reconChars.dropFirst(shorter)
            print("[LLM] Common prefix, then:")
            print("       original extra: \(origTail.isEmpty ? "<nothing>" : "\"\(String(origTail))\"")")
            print("       response extra: \(reconTail.isEmpty ? "<nothing>" : "\"\(String(reconTail))\"")")
            if let c = origTail.first { print("       original char scalars: \(scalars(c))") }
            if let c = reconTail.first { print("       response char scalars: \(scalars(c))") }
        }

        print("[LLM] Response segments (\(response.segments.count) total):")
        for (i, entry) in response.segments.enumerated() {
            let scalarStr = entry.surface.unicodeScalars.map { "U+\(String($0.value, radix: 16, uppercase: true))" }.joined(separator: " ")
            print("  [\(i)] \"\(entry.surface)\"  [\(scalarStr)]  reading: \"\(entry.reading)\"")
        }
    }

    // Encodes [LLMSegmentEntry] to compact human-readable format for LLM I/O.
    // Each segment is separated by `|`. Within a segment, each kanji run is annotated
    // as `(kanji)[reading]`; pure kana, punctuation, and whitespace pass through as-is.
    // Example: 生き方は → `(生)[い]き(方)[かた]|は|`
    func buildCompactFormat(from entries: [LLMSegmentEntry]) -> String {
        entries.map { entry in
            guard ScriptClassifier.containsKanji(entry.surface) else {
                return entry.surface
            }
            let runs = kanjiRuns(in: entry.surface)
            let chars = Array(entry.surface)
            guard runs.isEmpty == false else { return entry.surface }

            let runReadings = projectRunReadings(surface: entry.surface, reading: entry.reading)

            var result = ""
            var charIdx = 0
            for (runIdx, run) in runs.enumerated() {
                // Append any kana between the previous run and this one.
                if charIdx < run.start {
                    result += String(chars[charIdx..<run.start])
                }
                let runSurface = String(chars[run.start..<run.end])
                let reading = runReadings?[runIdx] ?? ""
                if reading.isEmpty {
                    result += runSurface
                } else {
                    result += "(\(runSurface))[\(reading)]"
                }
                charIdx = run.end
            }
            // Append trailing kana.
            if charIdx < chars.count {
                result += String(chars[charIdx...])
            }
            return result
        }.joined(separator: "|")
    }

    // Surfaces errors as alerts; successful corrections apply silently.
    private func handleLLMCorrectionResult(_ result: LLMCorrectionResult) {
        switch result {
        case .applied:
            break
        case .surfaceMismatch:
            llmCorrectionErrorMessage = "The LLM returned segments that don't match the original text. Try again."
            isShowingLLMCorrectionError = true
        case .networkError(let msg):
            llmCorrectionErrorMessage = msg
            isShowingLLMCorrectionError = true
        case .decodingError(let msg):
            llmCorrectionErrorMessage = msg
            isShowingLLMCorrectionError = true
        }
    }
}
