import SwiftUI

// Hosts LLM-driven segmentation and reading correction logic for the read screen.
// Converts current view state into a request payload, applies validated responses,
// and surfaces errors as alerts.
extension ReadView {

    // Builds the current segment + reading snapshot and sends it to the LLM for correction.
    // Streams per-line corrections back to the UI when the active provider supports it
    // (Apple Intelligence). Remote providers and stub mode return a single final response
    // which is applied once at the end. In both cases the apply path is the same; the
    // streaming variant just calls it multiple times with cumulative responses.
    func requestLLMCorrection() {
        guard llmCorrectionTask == nil else { return }

        let currentSegments = buildLLMSegmentEntries()
        guard currentSegments.isEmpty == false else {
            llmCorrectionErrorMessage = "No segments to correct. Make sure the note has content and segmentation has loaded."
            isShowingLLMCorrectionError = true
            return
        }

        let capturedText = text
        let compactSegments = LLMCorrectionDiagnostics.buildCompactFormat(from: currentSegments)
        let service = LLMCorrectionService()

        // Clear stale pending state before starting a fresh run. The streaming
        // path snapshots preLLMSegmentEntries on the first partial apply, so
        // any leftover snapshot from a prior session would corrupt the
        // reject-to-original path.
        pendingLLMChangedLocations = []
        pendingLLMChangedReadingLocations = []
        pendingLLMChangesByLocation = [:]
        preLLMSegmentEntries = []
        hasPendingLLMChanges = false

        // Only the on-device provider streams today. Remote and stub return a
        // single response; we apply it once at the end. Reading this once up
        // front avoids racing the @AppStorage value mid-request.
        let useLLM = UserDefaults.standard.bool(forKey: LLMSettings.useLLMKey)
        let willStream = useLLM && LLMSettings.activeProvider() == .appleIntelligence

        isRequestingLLMCorrection = true
        llmCorrectionTask = Task {
            defer {
                Task { @MainActor in
                    isRequestingLLMCorrection = false
                    llmCorrectionTask = nil
                }
            }

            do {
                let baselineSnapshot = currentSegments
                let response = try await service.requestCorrections(
                    compactSegments: compactSegments,
                    dictionary: dictionaryStore,
                    onPartial: willStream ? { @MainActor partial in
                        let merged = Self.mergeResponsePerLine(
                            response: partial,
                            originalText: capturedText,
                            baseline: baselineSnapshot
                        )
                        self.applyLLMStreamingPartial(merged, originalText: capturedText)
                    } : nil
                )

                await MainActor.run {
                    if willStream {
                        // Streaming already applied every line as it arrived;
                        // the final response equals the last partial. Just flag
                        // the note as having had a correction applied so a
                        // subsequent sparkles tap goes through the rerun-confirm
                        // dialog.
                        if hasPendingLLMChanges {
                            hasAppliedLLMCorrectionForCurrentNote = true
                        }
                    } else {
                        // Remote / stub one-shot — merge per-line with baseline
                        // first so a single bad line (e.g., gpt-4o-search-preview
                        // substituting kana → kanji on one row) doesn't tank
                        // the whole correction. Lines whose surfaces concat to
                        // the source line apply as-returned; the rest fall back
                        // to the baseline (no change for that line).
                        let merged = Self.mergeResponsePerLine(
                            response: response,
                            originalText: capturedText,
                            baseline: baselineSnapshot
                        )
                        let result = applyLLMCorrectionResponse(merged, originalText: capturedText)
                        handleLLMCorrectionResult(result)
                    }
                }
            } catch {
                await MainActor.run {
                    llmCorrectionErrorMessage = error.localizedDescription
                    isShowingLLMCorrectionError = true
                }
            }
        }
    }

    // Applies one streaming partial: runs the same apply path as the single-shot
    // case, then UNIONS the per-pass changed locations into the accumulated
    // pending state instead of overwriting. The pre-LLM snapshot is captured by
    // applyLLMCorrectionResponse on its first call of the run (when
    // preLLMSegmentEntries is empty) and preserved on subsequent calls.
    func applyLLMStreamingPartial(_ partial: LLMCorrectionResponse, originalText: String) {
        let result = applyLLMCorrectionResponse(partial, originalText: originalText)
        switch result {
        case .applied(_, let changedLocations, let changedReadingLocations, let changesByLocation):
            pendingLLMChangedLocations.formUnion(changedLocations)
            pendingLLMChangedReadingLocations.formUnion(changedReadingLocations)
            for (loc, desc) in changesByLocation {
                pendingLLMChangesByLocation[loc] = desc
            }
            if pendingLLMChangedLocations.isEmpty == false {
                hasPendingLLMChanges = true
            }
        case .surfaceMismatch(let msg), .networkError(let msg), .decodingError(let msg):
            // A streaming partial failed validation — the per-line client
            // sanitizes input so this is rare, but if it happens, log and
            // skip rather than failing the whole run.
            print("[LLM] streaming partial apply failed: \(msg)")
        }
    }

    // Per-line salvage pass over an LLM response: groups the response and the
    // baseline (pre-LLM segmentation) by note line, validates each response
    // line's surfaces against the corresponding source line, and substitutes
    // the baseline back in for lines that don't reconcile. This stops a
    // single bad line — typically gpt-4o-search-preview "normalizing" な → 成
    // somewhere — from rejecting the entire response. Returns a response that
    // is guaranteed to concat-equal originalText, modulo the existing
    // whitespace repair pass that applyLLMCorrectionResponse still runs.
    static func mergeResponsePerLine(
        response: LLMCorrectionResponse,
        originalText: String,
        baseline: [LLMSegmentEntry]
    ) -> LLMCorrectionResponse {
        let responseLines = groupSegmentsByNoteLine(response.segments)
        let baselineLines = groupSegmentsByNoteLine(baseline)
        let sourceLines = originalText.components(separatedBy: "\n")

        var merged: [LLMSegmentEntry] = []
        for (index, sourceLine) in sourceLines.enumerated() {
            let responseLine = index < responseLines.count ? responseLines[index] : []
            let baselineLine = index < baselineLines.count ? baselineLines[index] : []

            let responseConcat = responseLine.map(\.surface).joined()
            let useResponse = responseLine.isEmpty == false && responseConcat == sourceLine
            let chosen = useResponse ? responseLine : baselineLine
            merged.append(contentsOf: chosen)

            // Mirror parseCompactResponse's behavior: each content line is
            // followed by an implicit "\n" entry to separate it from the next.
            // Skip after the last line so we don't introduce a trailing
            // newline the source didn't have.
            if index < sourceLines.count - 1 {
                merged.append(LLMSegmentEntry(surface: "\n", reading: ""))
            }
        }
        return LLMCorrectionResponse(segments: merged)
    }

    // Splits a flat entry list into per-note-line groups using "\n"-surfaced
    // entries as the separator. The "\n" entries themselves are dropped; the
    // caller re-inserts them when re-assembling. An empty trailing group is
    // discarded so a response that ends with "\n" doesn't add a phantom line.
    private static func groupSegmentsByNoteLine(_ entries: [LLMSegmentEntry]) -> [[LLMSegmentEntry]] {
        var lines: [[LLMSegmentEntry]] = []
        var current: [LLMSegmentEntry] = []
        for entry in entries {
            if entry.surface == "\n" {
                lines.append(current)
                current = []
            } else if entry.surface.isEmpty == false {
                current.append(entry)
            }
        }
        if current.isEmpty == false {
            lines.append(current)
        }
        return lines
    }

    // Cancels any in-flight LLM correction request.
    func cancelLLMCorrection() {
        llmCorrectionTask?.cancel()
        llmCorrectionTask = nil
        isRequestingLLMCorrection = false
    }

    // Segment-start UTF-16 locations covering the note line the AI is processing
    // RIGHT NOW (per AICorrectionProgress.currentLineIndex). Used to drive a
    // per-line in-flight highlight so the user can see which line the model is
    // working on without watching a spinner. Returns an empty set when no AI
    // request is in flight, or when the published index doesn't map to a real
    // line in the current text (e.g., text changed mid-request).
    var inFlightLineSegmentLocations: Set<Int> {
        guard let lineIndex = aiProgress.currentLineIndex else { return [] }
        let lines = text.components(separatedBy: "\n")
        guard lineIndex >= 0, lineIndex < lines.count else { return [] }

        // Walk up to the target line, summing each prior line's UTF-16 count
        // plus one for the "\n" separator. Last line has no trailing newline,
        // which is fine because we never need its end offset.
        var lineStart = 0
        for i in 0..<lineIndex {
            lineStart += lines[i].utf16.count + 1
        }
        let lineEnd = lineStart + lines[lineIndex].utf16.count

        var locs: Set<Int> = []
        for edge in segmentEdges {
            let r = NSRange(edge.start..<edge.end, in: text)
            guard r.location != NSNotFound else { continue }
            if r.location >= lineStart, r.location < lineEnd {
                locs.insert(r.location)
            }
        }
        return locs
    }

    // Converts the current segment edges and reading overrides into LLMSegmentEntry values
    // so the LLM can see both the segmentation boundaries and the furigana assigned to each.
    func buildLLMSegmentEntries() -> [LLMSegmentEntry] {
        segmentEdges.compactMap { edge in
            let nsRange = NSRange(edge.start..<edge.end, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }

            // Segment-level furigana takes priority over per-run reconstructed readings.
            if let override = furiganaBySegmentLocation[nsRange.location] {
                return LLMSegmentEntry(surface: edge.surface, reading: override)
            }

            // Auto-computed furigana may be stored per kanji run rather than at the segment start.
            // Reconstruct the full reading by walking each run and interleaving kana between them.
            let reading = reconstructedReading(for: edge.surface, at: nsRange.location)
            return LLMSegmentEntry(surface: edge.surface, reading: reading)
        }
    }

    // Walks the kanji runs in a segment surface and reassembles a full reading from per-run
    // furigana entries stored in furiganaBySegmentLocation, interleaving any kana between runs.
    // Returns empty string if any run has no furigana, since a partial reading is unusable.
    func reconstructedReading(for surface: String, at segmentLocation: Int) -> String {
        let chars = Array(surface)
        let runs = kanjiRuns(in: surface)
        guard runs.isEmpty == false else { return "" }

        var reading = ""
        var charIdx = 0
        for run in runs {
            // Kana between the previous run and this one belongs in the reading as-is.
            if charIdx < run.start {
                reading += String(chars[charIdx..<run.start])
            }
            let prefixUTF16 = String(chars[..<run.start]).utf16.count
            let runLocation = segmentLocation + prefixUTF16
            guard let runReading = furiganaBySegmentLocation[runLocation], runReading.isEmpty == false else {
                return ""
            }
            reading += runReading
            charIdx = run.end
        }
        if charIdx < chars.count {
            reading += String(chars[charIdx...])
        }
        return reading
    }

    // Validates the LLM response and applies it using the same normalizedSegmentRanges +
    // edgesFromSegmentRanges pipeline used when restoring a note from import.
    private func applyLLMCorrectionResponse(
        _ response: LLMCorrectionResponse,
        originalText: String
    ) -> LLMCorrectionResult {
        // LLMs occasionally swap a space for a newline, drop a stray space, or insert one —
        // none of which change the underlying tokenization intent. Repair whitespace-only
        // discrepancies against the original text before validating so the correction still
        // applies. A non-whitespace divergence fails repair and surfaces as a mismatch.
        let workingEntries: [LLMSegmentEntry] = {
            let ranges = response.segments
                .filter { $0.surface.isEmpty == false }
                .map { SegmentRange(surface: $0.surface) }
            if normalizedSegmentRanges(ranges, for: originalText) != nil {
                return response.segments
            }
            return LLMCorrectionDiagnostics.repairWhitespaceMismatches(response.segments, against: originalText) ?? response.segments
        }()

        // Build order-only SegmentRange values from the (possibly repaired) response surfaces.
        let ranges: [SegmentRange] = workingEntries
            .filter { $0.surface.isEmpty == false }
            .map { SegmentRange(surface: $0.surface) }

        // Run the same contiguous-coverage validation used by loadSelectedNoteIfNeeded.
        guard let validatedRanges = normalizedSegmentRanges(ranges, for: originalText) else {
            let reconstructed = workingEntries.map(\.surface).joined()
            let msg = LLMCorrectionDiagnostics.mismatchDescription(original: originalText, reconstructed: reconstructed)
            LLMCorrectionDiagnostics.printMismatchReport(original: originalText, reconstructed: reconstructed, response: response)
            return .surfaceMismatch(msg)
        }

        // Rebuild LatticeEdge values from the validated UTF-16 ranges.
        guard let rebuiltEdges = edgesFromSegmentRanges(validatedRanges, in: originalText) else {
            // Logging disabled.
            // print("[LLM] edgesFromSegmentRanges returned nil despite passing normalizedSegmentRanges")
            return .surfaceMismatch("Segments validated but edge reconstruction failed — this is a bug.")
        }

        // Snapshot old state before mutating anything — used for diff and per-change undo.
        let oldFurigana = furiganaBySegmentLocation
        // For streaming, capture preLLMSegmentEntries on the FIRST apply of the
        // run only. Subsequent applies during a streaming run would otherwise
        // overwrite the snapshot with post-previous-apply state, breaking the
        // reject-to-original guarantee. The streaming entry point clears
        // preLLMSegmentEntries before kicking off, so an empty value here
        // means "first apply, snapshot now"; non-empty means "leave the
        // original snapshot in place." The single-shot path also benefits:
        // requestLLMCorrection always clears the snapshot first, so the
        // first apply still records it.
        if preLLMSegmentEntries.isEmpty {
            preLLMSegmentEntries = buildLLMSegmentEntries()
        }

        var diffLines: [String] = []
        var changedLocations: Set<Int> = []
        // Tracks locations where only the furigana reading changed; surface was untouched.
        // These locations color only the furigana, not the segment text.
        var changedReadingLocations: Set<Int> = []
        var changesByLocation: [Int: String] = [:]

        // Boundary diff: detect splits, merges, and simple substitutions, then emit
        // grouped descriptions so the popover shows the full picture at each changed location.
        // Format: `old → new` for substitutions, `old → a|b` for splits, `a|b → new` for merges.
        //
        // Strategy: for each new edge, find the old segment(s) that overlap its span.
        // Group new edges that share the same set of old segment(s).
        struct OldSeg { let location: Int; let end: Int; let surface: String }
        let oldSegs: [OldSeg] = segmentEdges.compactMap { edge in
            let r = NSRange(edge.start..<edge.end, in: originalText)
            guard r.location != NSNotFound else { return nil }
            return OldSeg(location: r.location, end: r.location + r.length, surface: edge.surface)
        }

        // Map each new edge to its overlapping old segments (by span overlap).
        struct NewSeg { let location: Int; let end: Int; let surface: String }
        var newSegs: [NewSeg] = []
        for edge in rebuiltEdges {
            let r = NSRange(edge.start..<edge.end, in: originalText)
            guard r.location != NSNotFound, r.length > 0 else { continue }
            newSegs.append(NewSeg(location: r.location, end: r.location + r.length, surface: edge.surface))
        }

        // Returns existing segments that spatially overlap a proposed new segment.
        func overlappingOld(for new: NewSeg) -> [OldSeg] {
            oldSegs.filter { $0.location < new.end && $0.end > new.location }
        }

        // Group new segments by the identity of their overlapping old segment(s).
        // Two new segs that overlap the same old seg(s) form one split group.
        var processed = Set<Int>() // new seg locations already handled
        for new in newSegs {
            guard processed.contains(new.location) == false else { continue }
            let old = overlappingOld(for: new)
            // Collect all new segments that overlap the same old span.
            let oldStart = old.map(\.location).min() ?? new.location
            let oldEnd   = old.map(\.end).max()   ?? new.end
            let siblings = newSegs.filter { $0.location >= oldStart && $0.end <= oldEnd }
            siblings.forEach { processed.insert($0.location) }

            let oldText = old.map(\.surface).joined(separator: "|")
            let newText = siblings.map(\.surface).joined(separator: "|")
            guard oldText != newText else { continue }

            let (line, col) = LLMCorrectionDiagnostics.lineCol(utf16Offset: new.location, in: originalText)
            let description = "\(oldText) → \(newText)"
            diffLines.append("Boundary line \(line), col \(col): \(description)")
            // Apply the same description to every new segment in the group so tapping
            // any piece shows the full split/merge context.
            for sib in siblings {
                changedLocations.insert(sib.location)
                changesByLocation[sib.location] = description
            }
        }

        // Apply the new edges as a persisted override, replacing any stale segmentation.
        applySegmentEdges(rebuiltEdges, persistOverride: true)

        // Pair rebuilt edges with response entries by index to apply readings.
        // Both arrays derive from the same source so counts should match;
        // zip truncates silently if they differ, which would skip tail entries.
        for (edge, entry) in zip(rebuiltEdges, workingEntries.filter { $0.surface.isEmpty == false }) {
            let nsRange = NSRange(edge.start..<edge.end, in: originalText)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }

            let location = nsRange.location

            if entry.reading.isEmpty {
                // Empty reading on a kanji-containing surface means the model
                // didn't supply one — preserve any existing furigana at this
                // location instead of clearing it. The small on-device model
                // routinely drops the `[reading]` annotation even when the
                // surface contains kanji; treating that as "clear the
                // furigana" leaves the kanji bare. Pure-kana surfaces never
                // had furigana to begin with, so the removal is a no-op
                // there — but we still do it explicitly so a true "clear"
                // signal works for kana segments whose state was stale.
                if ScriptClassifier.containsKanji(edge.surface) == false {
                    furiganaBySegmentLocation.removeValue(forKey: location)
                    furiganaLengthBySegmentLocation.removeValue(forKey: location)
                }
            } else {
                // Write per-kanji-run furigana via the shared helper — clears stale entries
                // overlapping the surface, then projects the reading over kanji runs so the
                // renderer centers each ruby span over its own run instead of being shifted
                // by okurigana. If projection fails (no okurigana to align by), helper writes
                // nothing and we explicitly drop the segment-level entry below.
                let wrote = applyPerRunFurigana(surface: edge.surface, reading: entry.reading, at: location)
                if !wrote {
                    furiganaBySegmentLocation.removeValue(forKey: location)
                    furiganaLengthBySegmentLocation.removeValue(forKey: location)
                }

                // Compare normalized display output against the pre-mutation snapshot so we aren't
                // fooled by full readings (たべる) vs already-stripped display values (た).
                let incoming = LLMCorrectionDiagnostics.normalizedDisplayReadings(surface: edge.surface, reading: entry.reading, baseLocation: location)
                let existing = LLMCorrectionDiagnostics.snapshotDisplayReadings(from: oldFurigana, for: edge.surface, baseLocation: location)
                if incoming != existing {
                    // Track as reading-only if the surface at this location was not already
                    // flagged as a boundary change (i.e. the segment text itself didn't change).
                    let isBoundaryChange = changedLocations.contains(location)
                    changedLocations.insert(location)
                    if isBoundaryChange == false {
                        changedReadingLocations.insert(location)
                    }
                    let oldReading = existing.values.sorted().joined(separator: "|")
                    let newReading = incoming.values.sorted().joined(separator: "|")
                    let (line, col) = LLMCorrectionDiagnostics.lineCol(utf16Offset: location, in: originalText)
                    if existing.isEmpty == false {
                        diffLines.append("Reading line \(line), col \(col): \"\(edge.surface)\" \(oldReading) → \(newReading)")
                        // Don't overwrite a boundary change description already set for this location.
                        if changesByLocation[location] == nil {
                            changesByLocation[location] = "\(oldReading) → \(newReading)"
                        }
                    } else {
                        diffLines.append("Reading line \(line), col \(col): \"\(edge.surface)\" → \(newReading)")
                        if changesByLocation[location] == nil {
                            changesByLocation[location] = "→ \(newReading)"
                        }
                    }
                }
            }
        }

        persistCurrentNoteIfNeeded()
        return .applied(diff: diffLines, changedLocations: changedLocations, changedReadingLocations: changedReadingLocations, changesByLocation: changesByLocation)
    }

    // Confirms pending LLM changes, clearing the highlight state set after a successful correction.
    func confirmLLMChanges() {
        pendingLLMChangedLocations = []
        pendingLLMChangedReadingLocations = []
        pendingLLMChangesByLocation = [:]
        preLLMSegmentEntries = []
        hasPendingLLMChanges = false
    }

    // Confirms a single pending change at the given location and clears it from pending state.
    // If this was the last pending change, accepts all (same effect as confirmLLMChanges).
    func confirmLLMChange(at location: Int) {
        // All siblings sharing the same change description are confirmed together.
        let description = pendingLLMChangesByLocation[location]
        let siblings = description.map { desc in
            pendingLLMChangesByLocation.filter { $0.value == desc }.map(\.key)
        } ?? [location]
        for loc in siblings {
            pendingLLMChangedLocations.remove(loc)
            pendingLLMChangedReadingLocations.remove(loc)
            pendingLLMChangesByLocation.removeValue(forKey: loc)
        }
        if pendingLLMChangedLocations.isEmpty {
            confirmLLMChanges()
        }
    }

    // Reverts the single pending change at the given location by re-applying the pre-LLM snapshot
    // for that group's span, leaving changes at other locations intact.
    // Falls back to a full revert when partial undo isn't possible (e.g. no snapshot).
    func rejectLLMChange(at location: Int) {
        guard preLLMSegmentEntries.isEmpty == false else {
            resetSegmentationToComputed()
            return
        }

        // Collect sibling locations that share the same change group (same description text).
        let description = pendingLLMChangesByLocation[location]
        let siblingLocations: [Int] = description.map { desc in
            pendingLLMChangesByLocation.filter { $0.value == desc }.map(\.key)
        } ?? [location]
        let groupStart = siblingLocations.min() ?? location
        let groupEnd: Int = {
            // Estimate group end from the rightmost sibling's current segment boundary.
            let maxLoc = siblingLocations.max() ?? location
            if let edge = segmentEdges.first(where: {
                NSRange($0.start..<$0.end, in: text).location == maxLoc
            }) {
                let r = NSRange(edge.start..<edge.end, in: text)
                return r.location + r.length
            }
            return maxLoc + 1
        }()

        // Build a merged entry list: current entries outside the group span, pre-LLM inside.
        var mergedEntries: [LLMSegmentEntry] = []
        var preCursor = 0
        for entry in preLLMSegmentEntries {
            let entryStart = preCursor
            preCursor += entry.surface.utf16.count
            if entryStart >= groupStart && entryStart < groupEnd {
                mergedEntries.append(entry)
            }
        }

        // Build the outside-group entries from current state and splice them around the reverted span.
        var outsideBefore: [LLMSegmentEntry] = []
        var outsideAfter: [LLMSegmentEntry] = []
        for edge in segmentEdges {
            let r = NSRange(edge.start..<edge.end, in: text)
            guard r.location != NSNotFound, r.length > 0 else { continue }
            if r.location + r.length <= groupStart {
                let reading = reconstructedReading(for: edge.surface, at: r.location)
                outsideBefore.append(LLMSegmentEntry(surface: edge.surface, reading: reading))
            } else if r.location >= groupEnd {
                let reading = reconstructedReading(for: edge.surface, at: r.location)
                outsideAfter.append(LLMSegmentEntry(surface: edge.surface, reading: reading))
            }
        }

        let fullEntries = outsideBefore + mergedEntries + outsideAfter
        guard fullEntries.isEmpty == false else {
            resetSegmentationToComputed()
            return
        }

        // Preserve snapshot before re-applying so subsequent rejects still have reference data.
        let savedSnapshot = preLLMSegmentEntries

        // Re-apply as a new LLM response so all pipeline invariants are satisfied.
        _ = applyLLMCorrectionResponse(
            LLMCorrectionResponse(segments: fullEntries),
            originalText: text
        )

        // Restore the original snapshot so other pending changes can still be individually reverted.
        preLLMSegmentEntries = savedSnapshot

        // Remove the reverted group from pending state.
        for loc in siblingLocations {
            pendingLLMChangedLocations.remove(loc)
            pendingLLMChangedReadingLocations.remove(loc)
            pendingLLMChangesByLocation.removeValue(forKey: loc)
        }
        if pendingLLMChangedLocations.isEmpty {
            confirmLLMChanges()
        }
    }
    // Surfaces errors as alerts; successful corrections store changed locations for UI highlighting.
    private func handleLLMCorrectionResult(_ result: LLMCorrectionResult) {
        switch result {
        case .applied(let diff, let changedLocations, let changedReadingLocations, let changesByLocation):
            _ = diff
            if changedLocations.isEmpty == false {
                pendingLLMChangedLocations = changedLocations
                pendingLLMChangedReadingLocations = changedReadingLocations
                pendingLLMChangesByLocation = changesByLocation
                hasPendingLLMChanges = true
                // This note now has an AI correction applied — future taps should confirm
                // before replacing it rather than re-running silently.
                hasAppliedLLMCorrectionForCurrentNote = true
            }
        case .surfaceMismatch(let msg):
            llmCorrectionErrorMessage = msg
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
