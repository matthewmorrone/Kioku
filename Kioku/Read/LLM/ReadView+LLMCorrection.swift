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
        // Logging disabled.
        // print("[LLM] Compact input:\n\(compactSegments)")
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
            return repairWhitespaceMismatches(response.segments, against: originalText) ?? response.segments
        }()

        // Build order-only SegmentRange values from the (possibly repaired) response surfaces.
        let ranges: [SegmentRange] = workingEntries
            .filter { $0.surface.isEmpty == false }
            .map { SegmentRange(surface: $0.surface) }

        // Run the same contiguous-coverage validation used by loadSelectedNoteIfNeeded.
        guard let validatedRanges = normalizedSegmentRanges(ranges, for: originalText) else {
            let reconstructed = workingEntries.map(\.surface).joined()
            let msg = mismatchDescription(original: originalText, reconstructed: reconstructed)
            printMismatchReport(original: originalText, reconstructed: reconstructed, response: response)
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
        preLLMSegmentEntries = buildLLMSegmentEntries()

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

            let (line, col) = lineCol(utf16Offset: new.location, in: originalText)
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
                furiganaBySegmentLocation.removeValue(forKey: location)
                furiganaLengthBySegmentLocation.removeValue(forKey: location)
            } else {
                // Write per-kanji-run furigana entries so the renderer centers over each run,
                // not the full segment (which includes okurigana and shifts the furigana right).
                let surfaceChars = Array(edge.surface)
                let runs = kanjiRuns(in: edge.surface)
                if runs.isEmpty == false,
                   let runReadings = FuriganaAttributedString.normalizedRunReadings(surface: edge.surface, reading: entry.reading, runs: runs),
                   runReadings.count == runs.count {
                    // Clear any stale segment-level entry before writing run-level entries.
                    furiganaBySegmentLocation.removeValue(forKey: location)
                    furiganaLengthBySegmentLocation.removeValue(forKey: location)
                    for (run, runReading) in zip(runs, runReadings) {
                        guard runReading.isEmpty == false else { continue }
                        let runSurface = String(surfaceChars[run.start..<run.end])
                        guard runReading != runSurface else { continue }
                        let prefixUTF16 = String(surfaceChars[..<run.start]).utf16.count
                        let runUTF16 = String(surfaceChars[run.start..<run.end]).utf16.count
                        furiganaBySegmentLocation[location + prefixUTF16] = runReading
                        furiganaLengthBySegmentLocation[location + prefixUTF16] = runUTF16
                    }
                } else {
                    furiganaBySegmentLocation.removeValue(forKey: location)
                    furiganaLengthBySegmentLocation.removeValue(forKey: location)
                }

                // Compare normalized display output against the pre-mutation snapshot so we aren't
                // fooled by full readings (たべる) vs already-stripped display values (た).
                let incoming = normalizedDisplayReadings(surface: edge.surface, reading: entry.reading, baseLocation: location)
                let existing = snapshotDisplayReadings(from: oldFurigana, for: edge.surface, baseLocation: location)
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
                    let (line, col) = lineCol(utf16Offset: location, in: originalText)
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

    // Returns the 1-based line and column for a UTF-16 offset in sourceText,
    // so diff entries pinpoint divergences without requiring a text editor search.
    private func lineCol(utf16Offset: Int, in sourceText: String) -> (line: Int, col: Int) {
        let nsString = sourceText as NSString
        let safeOffset = min(utf16Offset, nsString.length)
        var line = 1
        var col = 1
        for i in 0..<safeOffset {
            if nsString.character(at: i) == 0x000A { line += 1; col = 1 } else { col += 1 }
        }
        return (line, col)
    }

    // Returns the per-run display readings that would result from applying a given reading to a surface,
    // keyed by UTF-16 location. Used to compare intended display output without being fooled by
    // differences between full readings (たべる) and already-stripped ones (た).
    private func normalizedDisplayReadings(surface: String, reading: String, baseLocation: Int) -> [Int: String] {
        let chars = Array(surface)
        let runs = kanjiRuns(in: surface)
        guard runs.isEmpty == false else { return [:] }

        if let runReadings = FuriganaAttributedString.normalizedRunReadings(surface: surface, reading: reading, runs: runs),
           runReadings.count == runs.count {
            var result: [Int: String] = [:]
            for (run, runReading) in zip(runs, runReadings) {
                guard runReading.isEmpty == false else { continue }
                let prefixUTF16 = String(chars[..<run.start]).utf16.count
                result[baseLocation + prefixUTF16] = runReading
            }
            return result
        }

        return [:]
    }

    // Extracts display readings from a pre-mutation furigana snapshot for comparison.
    private func snapshotDisplayReadings(from snapshot: [Int: String], for surface: String, baseLocation: Int) -> [Int: String] {
        let utf16Length = surface.utf16.count
        return snapshot.filter { loc, _ in
            loc >= baseLocation && loc < baseLocation + utf16Length
        }
    }

    // Aligns response segment surfaces to the original text by tolerating whitespace-only
    // discrepancies: substitutions (' ' ↔ '\n', tab, U+3000), insertions (response dropped a
    // whitespace char), and deletions (response added a spurious whitespace char).
    // Returns repaired entries whose concatenated surfaces exactly equal the original text,
    // or nil when a non-whitespace mismatch is encountered. Readings are preserved.
    private func repairWhitespaceMismatches(
        _ entries: [LLMSegmentEntry],
        against originalText: String
    ) -> [LLMSegmentEntry]? {
        let origNS = originalText as NSString
        var origIdx = 0
        var repaired: [LLMSegmentEntry] = []

        for entry in entries {
            let segNS = entry.surface as NSString
            var segIdx = 0
            var units: [unichar] = []

            while segIdx < segNS.length {
                let segCh = segNS.character(at: segIdx)
                if origIdx >= origNS.length {
                    // Response has extra trailing characters — accept only if whitespace.
                    guard Self.isWhitespaceUnit(segCh) else { return nil }
                    segIdx += 1
                    continue
                }
                let origCh = origNS.character(at: origIdx)
                if origCh == segCh {
                    units.append(origCh)
                    origIdx += 1
                    segIdx += 1
                } else if Self.isWhitespaceUnit(origCh) && Self.isWhitespaceUnit(segCh) {
                    // Whitespace substitution — adopt the original's character.
                    units.append(origCh)
                    origIdx += 1
                    segIdx += 1
                } else if Self.isWhitespaceUnit(origCh) {
                    // Response dropped an original whitespace char — reinsert it.
                    units.append(origCh)
                    origIdx += 1
                } else if Self.isWhitespaceUnit(segCh) {
                    // Response added a spurious whitespace char — drop it.
                    segIdx += 1
                } else {
                    return nil
                }
            }

            let surface = String(utf16CodeUnits: units, count: units.count)
            repaired.append(LLMSegmentEntry(surface: surface, reading: entry.reading))
        }

        // Consume any trailing original whitespace the response never emitted by appending
        // to the last non-empty repaired entry.
        while origIdx < origNS.length {
            let ch = origNS.character(at: origIdx)
            guard Self.isWhitespaceUnit(ch) else { return nil }
            guard let lastIdx = repaired.lastIndex(where: { $0.surface.isEmpty == false }) else { return nil }
            let appended = repaired[lastIdx].surface + String(utf16CodeUnits: [ch], count: 1)
            repaired[lastIdx] = LLMSegmentEntry(surface: appended, reading: repaired[lastIdx].reading)
            origIdx += 1
        }

        guard origIdx == origNS.length else { return nil }
        return repaired
    }

    // Recognized whitespace UTF-16 units for mismatch repair: ASCII space/tab/CR/LF and
    // ideographic space (U+3000), which Japanese text commonly contains.
    private static func isWhitespaceUnit(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0x3000
    }

    // Builds a user-facing mismatch description listing every divergence with line/col,
    // a printable form of the differing characters, and a small context window. Multiple
    // issues matter because LLMs often produce a cluster of related mistakes; seeing only
    // the first one hides the others and makes the failure feel opaque.
    private func mismatchDescription(original: String, reconstructed: String) -> String {
        let origUTF16 = original.utf16.count
        let reconUTF16 = reconstructed.utf16.count

        let origChars = Array(original)
        let reconChars = Array(reconstructed)

        // Walk both sequences, emitting a numbered entry per contiguous run of
        // divergence. A run ends when characters realign or one side is exhausted.
        var issues: [String] = []
        let maxIssues = 5
        var i = 0
        let common = min(origChars.count, reconChars.count)
        while i < common && issues.count < maxIssues {
            if origChars[i] == reconChars[i] { i += 1; continue }
            let startIdx = i
            var j = i
            while j < common && origChars[j] != reconChars[j] { j += 1 }
            let origRun = String(origChars[startIdx..<j])
            let reconRun = String(reconChars[startIdx..<j])
            let (line, col) = lineCol(for: startIdx, in: origChars)
            issues.append("line \(line), col \(col): expected \(printable(origRun)) but got \(printable(reconRun))")
            i = j
        }

        // A run extending past the shared prefix shows as a trailing extra/missing tail.
        if issues.count < maxIssues && origChars.count != reconChars.count {
            let (line, col) = lineCol(for: common, in: origChars)
            if origChars.count > reconChars.count {
                let tail = String(origChars[common..<origChars.count])
                issues.append("line \(line), col \(col): response is missing \(printable(tail))")
            } else {
                let tail = String(reconChars[common..<reconChars.count])
                issues.append("line \(line), col \(col): response has extra \(printable(tail))")
            }
        }

        if issues.isEmpty == false {
            let header = "LLM response doesn't match the source text (\(origUTF16) vs \(reconUTF16) UTF-16 units, \(issues.count)\(issues.count >= maxIssues ? "+" : "") issue\(issues.count == 1 ? "" : "s")):"
            return header + "\n\n• " + issues.joined(separator: "\n• ")
        }


        // No character-level difference found — one is a prefix of the other.
        let delta = reconUTF16 - origUTF16
        let sign = delta > 0 ? "+" : ""
        return "Segment surfaces don't cover the full text (\(sign)\(delta) UTF-16 units). The response likely added or dropped characters."
    }

    // Computes 1-based line and column for a character index in a [Character] array.
    // Used by the mismatch description so each reported issue points at a precise location.
    private func lineCol(for charIndex: Int, in chars: [Character]) -> (line: Int, col: Int) {
        var line = 1
        var col = 1
        let end = min(charIndex, chars.count)
        for i in 0..<end {
            if chars[i] == "\n" { line += 1; col = 1 } else { col += 1 }
        }
        return (line, col)
    }

    // Renders a run of characters as a human-readable token: whitespace and control chars
    // become escape sequences (\n, \t, \u{3000}) so invisible differences are still legible
    // in an alert, while normal characters are shown quoted.
    private func printable(_ run: String) -> String {
        guard run.isEmpty == false else { return "''" }
        var result = ""
        for scalar in run.unicodeScalars {
            switch scalar.value {
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0x20: result += "·"
            case 0x3000: result += "\\u{3000}"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u{%X}", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return "'\(result)'"
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

        // Compute the line for a character index by scanning for newlines.
        func lineNumber(in chars: [Character], at idx: Int) -> Int {
            var line = 1
            for i in 0..<min(idx, chars.count) {
                if chars[i] == "\n" { line += 1 }
            }
            return line
        }

        // Logging disabled.
        // print("[LLM] Mismatch — original \(original.utf16.count) UTF-16 units, reconstructed \(reconstructed.utf16.count)")

        if let idx = zip(origChars, reconChars).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            let line = lineNumber(in: origChars, at: idx)
            // Logging disabled.
            // print("[LLM] First difference at line \(line), col \(col):")
            // print("       original : '\(origChar)'  \(scalars(origChar))")
            // print("       response : '\(reconChar)'  \(scalars(reconChar))")

            // Side-by-side context: 3 lines centred on the divergence line, aligned.
            let origLines = original.components(separatedBy: "\n")
            let reconLines = reconstructed.components(separatedBy: "\n")
            let firstLine = max(1, line - 1)
            let lastLine  = min(max(origLines.count, reconLines.count), line + 1)
            // Logging disabled.
            // print("[LLM] Context (line | original vs response):")
            _ = firstLine
            _ = lastLine
        } else {
            // Logging disabled.
            // print("[LLM] Common prefix, then:")
            // print("       original extra: \(origTail.isEmpty ? "<nothing>" : "\"\(String(origTail))\"")")
            // print("       response extra: \(reconTail.isEmpty ? "<nothing>" : "\"\(String(reconTail))\"")")
            // if let c = origTail.first { print("       original char scalars: \(scalars(c))") }
            // if let c = reconTail.first { print("       response char scalars: \(scalars(c))") }
        }

        // Logging disabled.
        // print("[LLM] Response segments (\(response.segments.count) total):")
        for (i, entry) in response.segments.enumerated() {
            let scalarStr = entry.surface.unicodeScalars.map { "U+\(String($0.value, radix: 16, uppercase: true))" }.joined(separator: " ")
            _ = i
            _ = scalarStr
            // Logging disabled.
            // print("  [\(i)] \"\(entry.surface)\"  [\(scalarStr)]  reading: \"\(entry.reading)\"")
        }
    }

    // Encodes [LLMSegmentEntry] to compact human-readable format for LLM I/O.
    // Each content line is `N|seg1|seg2|` where N is the 1-based source line number.
    // The line break itself encodes a single `\n`.
    // A bare `N|` line encodes an extra blank line (i.e. `\n\n` between surrounding content).
    // Example: A\nB\n\nC\n → `1|A|\n2|B|\n3|\n4|C|`
    func buildCompactFormat(from entries: [LLMSegmentEntry]) -> String {
        var outputLines: [String] = []
        var currentTokens: [String] = []
        // Tracks whether the last emitted line was a content line (vs a bare line-number marker).
        var lastWasContent = false
        // 1-based source line counter — increments each time a \n segment is consumed.
        var sourceLine = 1

        for entry in entries {
            if entry.surface == "\n" {
                if currentTokens.isEmpty == false {
                    // Flush pending content; the line break encodes this \n implicitly.
                    outputLines.append("\(sourceLine)|" + currentTokens.joined(separator: "|") + "|")
                    currentTokens = []
                    lastWasContent = true
                } else if lastWasContent {
                    // Second consecutive \n (blank line) — emit a bare line-number marker.
                    outputLines.append("\(sourceLine)|")
                    lastWasContent = false
                }
                // A third+ consecutive \n would need additional bare markers.
                // For now song/prose text only has at most double newlines.
                sourceLine += 1
            } else {
                currentTokens.append(compactToken(for: entry))
            }
        }
        if currentTokens.isEmpty == false {
            outputLines.append("\(sourceLine)|" + currentTokens.joined(separator: "|") + "|")
        }

        return outputLines.joined(separator: "\n")
    }

    // Formats a single segment entry as a compact token, annotating kanji runs as `(kanji)[reading]`.
    private func compactToken(for entry: LLMSegmentEntry) -> String {
        guard ScriptClassifier.containsKanji(entry.surface) else {
            return entry.surface
        }
        let runs = kanjiRuns(in: entry.surface)
        let chars = Array(entry.surface)
        guard runs.isEmpty == false else { return entry.surface }

        let runReadings = FuriganaAttributedString.normalizedRunReadings(surface: entry.surface, reading: entry.reading, runs: runs)

        var result = ""
        var charIdx = 0
        for (runIdx, run) in runs.enumerated() {
            if charIdx < run.start {
                result += String(chars[charIdx..<run.start])
            }
            let runSurface = String(chars[run.start..<run.end])
            let reading = runReadings?[runIdx] ?? ""
            result += reading.isEmpty ? runSurface : "(\(runSurface))[\(reading)]"
            charIdx = run.end
        }
        if charIdx < chars.count {
            result += String(chars[charIdx...])
        }
        return result
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
