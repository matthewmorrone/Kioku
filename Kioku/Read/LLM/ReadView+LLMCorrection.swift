import SwiftUI

// A currently-visible (baseline) segment span, used by stageLLMCorrectionResponse's boundary
// diff to detect splits, merges, and substitutions against the proposed segments
// (LLMCorrectionNewSeg).
private struct LLMCorrectionOldSeg {
    let location: Int
    let end: Int
    let surface: String
}

// A proposed (not-yet-applied) segment span — see LLMCorrectionOldSeg.
private struct LLMCorrectionNewSeg {
    let location: Int
    let end: Int
    let surface: String
}

// Hosts the read screen's AI segmentation correction: requests it (LLMCorrectionClient),
// validates the streamed answer against the note, stages it as a pending proposal, and surfaces
// errors as alerts. Nothing is written to the document until the user confirms each change in a
// popup — see stageLLMCorrectionResponse / confirmLLMChange.
extension ReadView {

    // Sends the note's current segmentation (manual edits included) for correction and streams
    // the answer back: the line the model is writing is highlighted, and each finished line's
    // suggestions are staged as pending changes as they arrive. Nothing is applied to the note —
    // every change waits for the user's confirm or reject in a popup.
    func requestLLMCorrection() {
        guard llmCorrection.llmCorrectionTask == nil else { return }
        let baseline = buildLLMSegmentEntries()
        guard baseline.isEmpty == false else {
            llmCorrection.llmCorrectionErrorMessage = "No segments to correct yet. Wait for the note to finish loading."
            llmCorrection.isShowingLLMCorrectionError = true
            return
        }
        let text = document.text
        let noteID = document.activeNoteID
        let compact = LLMCorrectionDiagnostics.buildCompactFormat(from: baseline)
        clearPendingLLMCorrectionState()
        llmCorrection.isRequestingLLMCorrection = true
        llmCorrection.inFlightLineIndex = 0

        llmCorrection.llmCorrectionTask = Task { @MainActor in
            defer {
                llmCorrection.isRequestingLLMCorrection = false
                llmCorrection.inFlightLineIndex = nil
                llmCorrection.llmCorrectionTask = nil
            }
            // Completed-line snapshots arrive off the main actor; the newest one is all that
            // matters, so older ones are dropped rather than queued.
            let (partials, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let request = Task { () throws -> String in
                defer { continuation.finish() }
                return try await LLMCorrectionClient.requestCorrection(compactSegments: compact) { completed in
                    continuation.yield(completed)
                }
            }
            do {
                let raw = try await withTaskCancellationHandler {
                    for await partial in partials {
                        guard document.activeNoteID == noteID, document.text == text else { continue }
                        applyLLMStreamingPartial(partial, originalText: text, baseline: baseline)
                    }
                    return try await request.value
                } onCancel: {
                    request.cancel()
                }
                // The user switched notes or edited the text mid-request: the answer no longer
                // lines up with what's on screen, so it's dropped rather than staged.
                guard Task.isCancelled == false, document.activeNoteID == noteID, document.text == text else { return }
                let response = try LLMCorrectionFormat.parseCompactResponse(raw)
                let merged = Self.mergeResponsePerLine(response: response, originalText: text, baseline: baseline)
                handleLLMCorrectionResult(stageLLMCorrectionResponse(merged, originalText: text))
            } catch {
                if Task.isCancelled || error is CancellationError {
                    AppLog.debug(.llmCorrection, "correction cancelled")
                    return
                }
                AppLog.error(.llmCorrection, "correction failed: \(error)")
                llmCorrection.llmCorrectionErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                llmCorrection.isShowingLLMCorrectionError = true
            }
        }
    }

    // Stages the response so far: lines the model has finished carry its suggestions, lines it
    // hasn't reached yet fall back to the current segmentation (see mergeResponsePerLine), so the
    // pending state is REPLACED each time rather than accumulated. Also moves the in-progress
    // highlight to the line being written. A partial that doesn't parse or reconcile yet is
    // skipped — the next completed line gets another chance.
    func applyLLMStreamingPartial(_ partialText: String, originalText: String, baseline: [LLMSegmentEntry]) {
        llmCorrection.inFlightLineIndex = LLMCorrectionClient.completedLineCount(in: partialText)
        guard let partial = try? LLMCorrectionFormat.parseCompactResponse(partialText) else { return }
        let merged = Self.mergeResponsePerLine(response: partial, originalText: originalText, baseline: baseline)
        if case .applied(_, let changedLocations, let changedReadingLocations, let changesByLocation) = stageLLMCorrectionResponse(merged, originalText: originalText) {
            llmCorrection.pendingLLMChangedLocations = changedLocations
            llmCorrection.pendingLLMChangedReadingLocations = changedReadingLocations
            llmCorrection.pendingLLMChangesByLocation = changesByLocation
            llmCorrection.hasPendingLLMChanges = changedLocations.isEmpty == false
        }
    }

    // Cancels the in-flight correction. Suggestions already staged stay pending for review.
    func cancelLLMCorrection() {
        llmCorrection.llmCorrectionTask?.cancel()
    }

    // Segment-start UTF-16 locations on the note line the model is writing right now, for the
    // renderer's in-progress tint. Empty when no correction is streaming or the index no longer
    // maps to a line of the current text.
    var inFlightLineSegmentLocations: Set<Int> {
        guard let lineIndex = llmCorrection.inFlightLineIndex else { return [] }
        let lines = document.text.components(separatedBy: "\n")
        guard lineIndex >= 0, lineIndex < lines.count else { return [] }
        // Walk to the target line, summing each prior line's UTF-16 length plus its "\n".
        var lineStart = 0
        for i in 0..<lineIndex {
            lineStart += lines[i].utf16.count + 1
        }
        let lineEnd = lineStart + lines[lineIndex].utf16.count
        var locations: Set<Int> = []
        for edge in document.segmentEdges {
            let range = NSRange(edge.start..<edge.end, in: document.text)
            guard range.location != NSNotFound else { continue }
            if range.location >= lineStart, range.location < lineEnd {
                locations.insert(range.location)
            }
        }
        return locations
    }

    // Per-line salvage pass over an LLM response: groups the response and the
    // baseline (pre-LLM segmentation) by note line, validates each response
    // line's surfaces against the corresponding source line, and substitutes
    // the baseline back in for lines that don't reconcile. This stops a
    // single bad line — typically gpt-4o-search-preview "normalizing" な → 成
    // somewhere — from rejecting the entire response. Returns a response that
    // is guaranteed to concat-equal originalText, modulo the existing
    // whitespace repair pass that stageLLMCorrectionResponse still runs.
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

    // Converts the current segment edges and reading overrides into LLMSegmentEntry values
    // so the LLM can see both the segmentation boundaries and the furigana assigned to each.
    func buildLLMSegmentEntries() -> [LLMSegmentEntry] {
        document.segmentEdges.compactMap { edge in
            let nsRange = NSRange(edge.start..<edge.end, in: document.text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }

            // Segment-level furigana takes priority over per-run reconstructed readings — but
            // only when the entry at this location actually COVERS the whole segment. A kanji
            // run that starts at offset 0 of a multi-character segment (e.g. "大切にしてた",
            // where the "大切" run starts at the segment's own start) writes its per-run entry
            // at this exact same key, with furiganaLengthBySegmentLocation set to the RUN's
            // length, not the segment's. Treating that as a segment-level override silently
            // truncated the reading to just the run's kana (e.g. "たいせつ" instead of
            // "たいせつにしてた"), which then failed okurigana projection downstream and showed
            // up as the correction UI's "(cleared)" reports. Comparing lengths distinguishes a
            // genuine whole-segment override from a same-keyed per-run entry.
            if let override = document.furiganaBySegmentLocation[nsRange.location],
               document.furiganaLengthBySegmentLocation[nsRange.location] == nsRange.length {
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
            guard let runReading = document.furiganaBySegmentLocation[runLocation], runReading.isEmpty == false else {
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

    // Validates the LLM response using the same normalizedSegmentRanges + edgesFromSegmentRanges
    // pipeline used when restoring a note from import, then computes what would change against
    // the current (still-untouched) document. Nothing is written here — the proposal is held in
    // llmCorrection.pendingLLMRebuiltEdges/pendingLLMWorkingEntries until confirmLLMChange(s)
    // actually applies it, so corrections stay invisible in the live text until confirmed.
    private func stageLLMCorrectionResponse(
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

        // Rebuild LatticeEdge values from the validated UTF-16 ranges. This is the PROPOSED
        // segmentation — document.segmentEdges is left untouched until confirmed.
        guard let rebuiltEdges = edgesFromSegmentRanges(validatedRanges, in: originalText) else {
            AppLog.error(.llmCorrection, "edgesFromSegmentRanges returned nil despite passing normalizedSegmentRanges — this is a bug")
            return .surfaceMismatch("Segments validated but edge reconstruction failed — this is a bug.")
        }

        let oldFurigana = document.furiganaBySegmentLocation

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
        let oldSegs: [LLMCorrectionOldSeg] = document.segmentEdges.compactMap { edge in
            let r = NSRange(edge.start..<edge.end, in: originalText)
            guard r.location != NSNotFound else { return nil }
            return LLMCorrectionOldSeg(location: r.location, end: r.location + r.length, surface: edge.surface)
        }

        // Map each new edge to its overlapping old segments (by span overlap).
        var newSegs: [LLMCorrectionNewSeg] = []
        for edge in rebuiltEdges {
            let r = NSRange(edge.start..<edge.end, in: originalText)
            guard r.location != NSNotFound, r.length > 0 else { continue }
            newSegs.append(LLMCorrectionNewSeg(location: r.location, end: r.location + r.length, surface: edge.surface))
        }

        // Returns existing segments that spatially overlap a proposed new segment.
        func overlappingOld(for new: LLMCorrectionNewSeg) -> [LLMCorrectionOldSeg] {
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

            let (line, col) = LLMCorrectionDiagnostics.lineCol(utf16Offset: oldStart, in: originalText)
            let description = "\(oldText) → \(newText)"
            diffLines.append("Boundary line \(line), col \(col): \(description)")
            // Key by the OLD (currently visible) segment locations, not the proposed new
            // ones — nothing has been applied yet, so the highlight and tap target need to
            // land on text that's actually on screen right now.
            for oldSeg in old {
                changedLocations.insert(oldSeg.location)
                changesByLocation[oldSeg.location] = description
            }
        }

        // Reading diff: compare each proposed entry's reading against the current furigana at
        // its location. Only a comparison — nothing is written to
        // document.furiganaBySegmentLocation here; that happens in applyPendingSegmentation
        // once the correction (or this one group) is confirmed.
        for (edge, entry) in zip(rebuiltEdges, workingEntries.filter { $0.surface.isEmpty == false }) {
            let nsRange = NSRange(edge.start..<edge.end, in: originalText)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }
            guard entry.reading.isEmpty == false else { continue }

            let location = nsRange.location

            // Compare normalized display output against the current furigana so we aren't
            // fooled by full readings (たべる) vs already-stripped display values (た).
            let incoming = LLMCorrectionDiagnostics.normalizedDisplayReadings(
                surface: edge.surface,
                reading: entry.reading,
                baseLocation: location
            )
            let existing = LLMCorrectionDiagnostics.snapshotDisplayReadings(from: oldFurigana, for: edge.surface, baseLocation: location)
            guard incoming != existing else { continue }

            // Track as reading-only if this location wasn't already flagged as a boundary
            // change (i.e. the segment text itself didn't change).
            let isBoundaryChange = changedLocations.contains(location)
            changedLocations.insert(location)
            if isBoundaryChange == false {
                changedReadingLocations.insert(location)
            }
            let oldReading = existing.values.sorted().joined(separator: "|")
            // normalizedDisplayReadings returns [:] whenever it can't split entry.reading across
            // edge.surface's kanji runs (e.g. the proposed reading's okurigana doesn't
            // phonetically match the surface). applyPerRunFurigana hits the exact same failure
            // at confirm time and falls back to clearing the furigana at this location — so an
            // empty `incoming` here isn't a display glitch, it's a preview of that real outcome.
            // existing can't be empty in this branch: an empty incoming with an empty existing
            // would have failed the `incoming != existing` guard above and never reached here.
            let (line, col) = LLMCorrectionDiagnostics.lineCol(utf16Offset: location, in: originalText)
            let description: String
            if incoming.isEmpty {
                description = "\(oldReading) → (cleared)"
            } else {
                let newReading = incoming.values.sorted().joined(separator: "|")
                description = existing.isEmpty ? "→ \(newReading)" : "\(oldReading) → \(newReading)"
            }
            diffLines.append("Reading line \(line), col \(col): \"\(edge.surface)\" \(description)")
            // Don't overwrite a boundary change description already set for this location.
            if changesByLocation[location] == nil {
                changesByLocation[location] = description
            }
        }

        llmCorrection.pendingLLMRebuiltEdges = rebuiltEdges
        llmCorrection.pendingLLMWorkingEntries = workingEntries
        return .applied(
            diff: diffLines,
            changedLocations: changedLocations,
            changedReadingLocations: changedReadingLocations,
            changesByLocation: changesByLocation
        )
    }

    // Writes a fully-resolved edge/entry set to the document — segmentation boundaries and
    // furigana — then persists. Shared by "confirm all" (the whole pending proposal) and
    // "confirm one" (a splice of the current document plus one pending group's slice).
    private func applyPendingSegmentation(edges: [LatticeEdge], entries: [LLMSegmentEntry], originalText: String) {
        applySegmentEdges(edges, persistOverride: true)

        // Pair edges with entries by index to apply readings. Both arrays derive from the same
        // source so counts should match; zip truncates silently if they differ, which would
        // skip tail entries.
        for (edge, entry) in zip(edges, entries.filter { $0.surface.isEmpty == false }) {
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
                    document.furiganaBySegmentLocation.removeValue(forKey: location)
                    document.furiganaLengthBySegmentLocation.removeValue(forKey: location)
                }
            } else {
                // Write per-kanji-run furigana via the shared helper — clears stale entries
                // overlapping the surface, then projects the reading over kanji runs so the
                // renderer centers each ruby span over its own run instead of being shifted
                // by okurigana. If projection fails (no okurigana to align by), helper writes
                // nothing and we explicitly drop the segment-level entry below.
                let wrote = applyPerRunFurigana(surface: edge.surface, reading: entry.reading, at: location)
                if !wrote {
                    document.furiganaBySegmentLocation.removeValue(forKey: location)
                    document.furiganaLengthBySegmentLocation.removeValue(forKey: location)
                }
            }
        }

        // Rebuild `segments` from segmentEdges + the furigana maps as they stand now (after the
        // per-run loop above), then persist. applySegmentEdges already persisted once above, but
        // that snapshot predates this loop's furigana writes — persistCurrentNoteIfNeeded() alone
        // would re-save that stale `segments` value and silently drop every reading the correction
        // wrote, since furiganaBySegmentLocation isn't part of what gets persisted directly.
        rebuildAndPersistSegments()
    }

    // Confirms and applies every still-pending change, one group at a time via
    // confirmLLMChange(at:) so a change already individually confirmed or rejected earlier
    // isn't re-applied or resurrected.
    func confirmLLMChanges() {
        while let location = llmCorrection.pendingLLMChangedLocations.first {
            confirmLLMChange(at: location)
        }
        clearPendingLLMCorrectionState()
    }

    // Clears pending-correction UI state without touching the document. Shared by confirm
    // (called after applying) and reject (which never applied anything to begin with).
    private func clearPendingLLMCorrectionState() {
        llmCorrection.pendingLLMChangedLocations = []
        llmCorrection.pendingLLMChangedReadingLocations = []
        llmCorrection.pendingLLMChangesByLocation = [:]
        llmCorrection.pendingLLMRebuiltEdges = []
        llmCorrection.pendingLLMWorkingEntries = []
        llmCorrection.hasPendingLLMChanges = false
    }

    // Rejects every pending change. Nothing was ever written to the document, so this is just
    // clearing the proposal.
    func rejectAllPendingLLMChanges() {
        clearPendingLLMCorrectionState()
    }

    // Confirms a single pending change at the given location: splices that group's proposed
    // edges into the document — which still reflects baseline plus any other already-confirmed
    // groups, since nothing is written until confirmed — and writes the corresponding furigana.
    // Every other pending group is left exactly as-is, still invisible until its own
    // confirm/reject.
    func confirmLLMChange(at location: Int) {
        // All siblings sharing the same change description are confirmed together.
        let description = llmCorrection.pendingLLMChangesByLocation[location]
        let siblingLocations: [Int] = description.map { desc in
            llmCorrection.pendingLLMChangesByLocation.filter { $0.value == desc }.map(\.key)
        } ?? [location]
        let groupStart = siblingLocations.min() ?? location
        // Estimate group end from the rightmost sibling's current (still-baseline, or
        // previously-confirmed) segment boundary — the span actually on screen right now.
        let groupEnd: Int = {
            let maxLoc = siblingLocations.max() ?? location
            if let edge = document.segmentEdges.first(where: {
                NSRange($0.start..<$0.end, in: document.text).location == maxLoc
            }) {
                let r = NSRange(edge.start..<edge.end, in: document.text)
                return r.location + r.length
            }
            return maxLoc + 1
        }()

        // This group's slice of the pending proposal: proposed edges whose location falls
        // inside the group's span.
        let proposedNonEmpty = llmCorrection.pendingLLMWorkingEntries.filter { $0.surface.isEmpty == false }
        var proposedInGroup: [LLMSegmentEntry] = []
        for (edge, entry) in zip(llmCorrection.pendingLLMRebuiltEdges, proposedNonEmpty) {
            let r = NSRange(edge.start..<edge.end, in: document.text)
            guard r.location != NSNotFound else { continue }
            if r.location >= groupStart && r.location < groupEnd {
                proposedInGroup.append(entry)
            }
        }

        // Current entries outside the group span — baseline, or already-confirmed from an
        // earlier call.
        var outsideBefore: [LLMSegmentEntry] = []
        var outsideAfter: [LLMSegmentEntry] = []
        for edge in document.segmentEdges {
            let r = NSRange(edge.start..<edge.end, in: document.text)
            guard r.location != NSNotFound, r.length > 0 else { continue }
            if r.location + r.length <= groupStart {
                let reading = reconstructedReading(for: edge.surface, at: r.location)
                outsideBefore.append(LLMSegmentEntry(surface: edge.surface, reading: reading))
            } else if r.location >= groupEnd {
                let reading = reconstructedReading(for: edge.surface, at: r.location)
                outsideAfter.append(LLMSegmentEntry(surface: edge.surface, reading: reading))
            }
        }

        let fullEntries = outsideBefore + proposedInGroup + outsideAfter
        let spliceRanges = fullEntries.filter { $0.surface.isEmpty == false }.map { SegmentRange(surface: $0.surface) }
        guard fullEntries.isEmpty == false,
              let validated = normalizedSegmentRanges(spliceRanges, for: document.text),
              let splicedEdges = edgesFromSegmentRanges(validated, in: document.text) else {
            // Splice didn't validate (shouldn't normally happen) — drop just this group
            // rather than recursing into confirmLLMChanges(), which would retry the same
            // group forever.
            AppLog.error(
                .llmCorrection,
                "confirmLLMChange: splice failed to validate for group at \(location) — dropping this pending change"
            )
            for loc in siblingLocations {
                llmCorrection.pendingLLMChangedLocations.remove(loc)
                llmCorrection.pendingLLMChangedReadingLocations.remove(loc)
                llmCorrection.pendingLLMChangesByLocation.removeValue(forKey: loc)
            }
            if llmCorrection.pendingLLMChangedLocations.isEmpty {
                clearPendingLLMCorrectionState()
            }
            return
        }

        applyPendingSegmentation(edges: splicedEdges, entries: fullEntries, originalText: document.text)

        for loc in siblingLocations {
            llmCorrection.pendingLLMChangedLocations.remove(loc)
            llmCorrection.pendingLLMChangedReadingLocations.remove(loc)
            llmCorrection.pendingLLMChangesByLocation.removeValue(forKey: loc)
        }
        if llmCorrection.pendingLLMChangedLocations.isEmpty {
            clearPendingLLMCorrectionState()
        }
    }

    // Rejects a single pending change at the given location. Nothing was ever written to the
    // document for it, so rejecting is just dropping it from the pending state.
    func rejectLLMChange(at location: Int) {
        let description = llmCorrection.pendingLLMChangesByLocation[location]
        let siblingLocations: [Int] = description.map { desc in
            llmCorrection.pendingLLMChangesByLocation.filter { $0.value == desc }.map(\.key)
        } ?? [location]
        for loc in siblingLocations {
            llmCorrection.pendingLLMChangedLocations.remove(loc)
            llmCorrection.pendingLLMChangedReadingLocations.remove(loc)
            llmCorrection.pendingLLMChangesByLocation.removeValue(forKey: loc)
        }
        if llmCorrection.pendingLLMChangedLocations.isEmpty {
            clearPendingLLMCorrectionState()
        }
    }
    // Surfaces errors as alerts; successful corrections store changed locations for UI highlighting.
    private func handleLLMCorrectionResult(_ result: LLMCorrectionResult) {
        switch result {
        case .applied(let diff, let changedLocations, let changedReadingLocations, let changesByLocation):
            if diff.isEmpty == false {
                AppLog.debug(.llmCorrection, "applied correction — \(diff.count) change(s):\n\(diff.joined(separator: "\n"))")
            }
            if changedLocations.isEmpty == false {
                llmCorrection.pendingLLMChangedLocations = changedLocations
                llmCorrection.pendingLLMChangedReadingLocations = changedReadingLocations
                llmCorrection.pendingLLMChangesByLocation = changesByLocation
                llmCorrection.hasPendingLLMChanges = true
            }
        case .surfaceMismatch(let msg):
            AppLog.error(.llmCorrection, "surface mismatch: \(msg)")
            llmCorrection.llmCorrectionErrorMessage = msg
            llmCorrection.isShowingLLMCorrectionError = true
        case .networkError(let msg):
            AppLog.error(.llmCorrection, "network error: \(msg)")
            llmCorrection.llmCorrectionErrorMessage = msg
            llmCorrection.isShowingLLMCorrectionError = true
        case .decodingError(let msg):
            AppLog.error(.llmCorrection, "decoding error: \(msg)")
            llmCorrection.llmCorrectionErrorMessage = msg
            llmCorrection.isShowingLLMCorrectionError = true
        }
    }
}
