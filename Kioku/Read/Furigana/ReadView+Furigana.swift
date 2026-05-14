import SwiftUI
import UIKit

// Hosts furigana computation and reading selection helpers for the read screen.
extension ReadView {
    // Public entry point: queues a furigana-generation request for user confirmation. The
    // actual work happens in performScheduleFuriganaGeneration once the user taps Confirm.
    // No-op when there's nothing to annotate — kana-only or empty edge sets never need a prompt.
    func scheduleFuriganaGeneration(for sourceText: String, edges: [LatticeEdge], reason: String = #function) {
        guard edges.contains(where: { ScriptClassifier.containsKanji($0.surface) }) else { return }
        requestAutoSegConfirm(
            reason: "scheduleFuriganaGeneration ← \(reason)",
            action: .scheduleFuriganaGeneration(sourceText: sourceText, edges: edges)
        )
    }

    // Computes furigana off-main and applies only the latest result for the current editor text.
    // Apply uses backfill semantics: existing entries are never overwritten (so user pins and
    // already-correct annotations stay put), but missing per-run annotations get filled in.
    // Renamed to performScheduleFuriganaGeneration because the public entry point above queues
    // a confirm prompt (see requestAutoSegConfirm) before invoking this worker.
    func performScheduleFuriganaGeneration(for sourceText: String, edges: [LatticeEdge]) {
        StartupTimer.mark("scheduleFuriganaGeneration called (\(edges.count) edges)")
        furiganaComputationTask?.cancel()
        let currentSurfaceReadingData = surfaceReadingData
        let hasKanjiEdges = edges.contains { edge in
            ScriptClassifier.containsKanji(edge.surface)
        }

        furiganaComputationTask = Task(priority: .userInitiated) {
            let furiganaResult = StartupTimer.measure("buildFuriganaBySegmentLocation (\(edges.count) edges)") {
                buildFuriganaBySegmentLocation(
                    for: sourceText,
                    edges: edges,
                    surfaceReadingData: currentSurfaceReadingData
                )
            }

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                // Bail when text changed mid-flight (load races, edits) or when segmentEdges
                // got cleared (we'd otherwise rebuild segments from an empty edge list and
                // wipe the user's merges/splits). Splits and merges happen IN edit mode, so
                // the compute pass MUST be allowed to apply during edit mode — otherwise
                // merging 抜け+殻 leaves the trailing 殻 with no per-run reading until the
                // user exits edit mode and triggers another recompute.
                guard
                    Task.isCancelled == false,
                    text == sourceText,
                    segmentEdges.isEmpty == false
                else {
                    return
                }

                StartupTimer.mark("applying furigana result to UI")

                // Skip backfill when the recompute returns nothing but in-memory entries still
                // exist (typically resources-not-ready races). Synthesis still runs below so a
                // user merge can collapse per-character fragments into one ruby span even when
                // the recompute had nothing new to contribute.
                let shouldRunBackfill = !(hasKanjiEdges
                    && furiganaResult.furiganaByLocation.isEmpty
                    && furiganaBySegmentLocation.isEmpty == false)

                let intermediate: (byLocation: [Int: String], lengthByLocation: [Int: Int])
                if shouldRunBackfill {
                    // Replace-on-overlap backfill: a new annotation that strictly contains existing
                    // entries (e.g. ものがたり at [L, L+2) covering prior per-character entries from
                    // a pre-merge segmentation of 物 + 語) supersedes those fragments. Otherwise
                    // additive backfill — existing entries at same range are kept (preserves user
                    // pins and prior-correct annotations) and gaps are filled.
                    intermediate = furiganaAfterApplyingNewAnnotations(
                        existingByLocation: furiganaBySegmentLocation,
                        existingLengthByLocation: furiganaLengthBySegmentLocation,
                        newByLocation: furiganaResult.furiganaByLocation,
                        newLengthByLocation: furiganaResult.lengthByLocation
                    )
                } else {
                    intermediate = (
                        byLocation: furiganaBySegmentLocation,
                        lengthByLocation: furiganaLengthBySegmentLocation
                    )
                }

                // Synthesis fallback: when the recompute has no compound reading for a merged
                // surface (e.g. a coined name like 月色) but per-character entries (つき + いろ)
                // tile the kanji run completely, concatenate them into a single span "つきいろ".
                // Gated on shouldRunBackfill to avoid the cold-start pollution where synthesis
                // ran with empty resources and concatenated per-character fragments into bogus
                // wide entries (e.g. ものご for 物語) that then got persisted and resisted
                // replacement. When backfill is skipped (resources unloaded → recompute empty),
                // synthesis is skipped too; the next recompute (after resources load) re-runs
                // both passes against fresh dict data.
                let synthesized: (byLocation: [Int: String], lengthByLocation: [Int: Int])
                if shouldRunBackfill {
                    synthesized = furiganaAfterSynthesizingCompoundReadings(
                        furiganaByLocation: intermediate.byLocation,
                        furiganaLengthByLocation: intermediate.lengthByLocation,
                        edges: segmentEdges,
                        sourceText: sourceText
                    )
                } else {
                    synthesized = intermediate
                }
                furiganaBySegmentLocation = synthesized.byLocation
                furiganaLengthBySegmentLocation = synthesized.lengthByLocation

                // Persist segments with furigana now that readings are fully resolved.
                // Assign back to self.segments so persistCurrentNoteIfNeeded writes the annotated data.
                segments = buildSegmentRanges(
                    from: segmentEdges,
                    furiganaByLocation: furiganaBySegmentLocation,
                    furiganaLengthByLocation: furiganaLengthBySegmentLocation
                )
                recordRuntimeSegmentationSnapshot(for: segmentEdges)
                persistCurrentNoteIfNeeded()
            }
        }
    }

    // Resolves per-segment furigana keyed by UTF-16 location so UIKit ranges can apply ruby text.
    func buildFuriganaBySegmentLocation(
        for sourceText: String,
        edges: [LatticeEdge],
        surfaceReadingData: SurfaceReadingDataMap
    ) -> (furiganaByLocation: [Int: String], lengthByLocation: [Int: Int]) {
        var resolvedFurigana: [Int: String] = [:]
        var resolvedFuriganaLengths: [Int: Int] = [:]

        for edge in edges {
            let segmentRange = edge.start..<edge.end
            let segmentSurface = edge.surface
            // Skip non-kanji segments to avoid redundant ruby annotations.
            guard ScriptClassifier.containsKanji(segmentSurface) else {
                continue
            }

            let annotations = furiganaAnnotations(
                for: segmentSurface,
                segmentRange: segmentRange,
                sourceText: sourceText,
                lemmaReference: segmenter.preferredLemma(for: segmentSurface) ?? segmentSurface,
                surfaceReadingData: surfaceReadingData
            )
            if annotations.isEmpty {
                continue
            }

            for annotation in annotations {
                guard let localStart = sourceText.index(
                    segmentRange.lowerBound,
                    offsetBy: annotation.localStartOffset,
                    limitedBy: segmentRange.upperBound
                ) else {
                    continue
                }

                guard let localEnd = sourceText.index(
                    localStart,
                    offsetBy: annotation.localLength,
                    limitedBy: segmentRange.upperBound
                ) else {
                    continue
                }

                let nsRange = NSRange(localStart..<localEnd, in: sourceText)
                if nsRange.location == NSNotFound || nsRange.length == 0 {
                    continue
                }

                resolvedFurigana[nsRange.location] = annotation.reading
                resolvedFuriganaLengths[nsRange.location] = nsRange.length
            }

            let segmentNSRange = NSRange(segmentRange, in: sourceText)
            if segmentHasAttachedFurigana(
                segmentNSRange: segmentNSRange,
                furiganaByLocation: resolvedFurigana,
                lengthByLocation: resolvedFuriganaLengths
            ) == false,
               let fallbackReading = fallbackSegmentFuriganaReading(
                for: edge,
                surfaceReadingData: surfaceReadingData,
                sourceText: sourceText
               ) {
                resolvedFurigana[segmentNSRange.location] = fallbackReading
                resolvedFuriganaLengths[segmentNSRange.location] = segmentNSRange.length
            }
        }

        return (furiganaByLocation: resolvedFurigana, lengthByLocation: resolvedFuriganaLengths)
    }

    // Verifies that a kanji-bearing segment has at least one ruby annotation overlapping its range.
    func segmentHasAttachedFurigana(
        segmentNSRange: NSRange,
        furiganaByLocation: [Int: String],
        lengthByLocation: [Int: Int]
    ) -> Bool {
        for location in furiganaByLocation.keys {
            guard let length = lengthByLocation[location], length > 0 else {
                continue
            }

            let annotationRange = NSRange(location: location, length: length)
            if NSIntersectionRange(annotationRange, segmentNSRange).length > 0 {
                return true
            }
        }

        return false
    }

    // Synthesizes a segment-level reading when run-level furigana alignment fails for a kanji segment.
    func fallbackSegmentFuriganaReading(
        for edge: LatticeEdge,
        surfaceReadingData: SurfaceReadingDataMap,
        sourceText: String
    ) -> String? {
        let preferredLemmaReference = preferredFuriganaLemmaReference(
            for: edge.surface,
            lemmaReference: segmenter.preferredLemma(for: edge.surface) ?? edge.surface
        )

        if let surfaceReading = readingForSegment(
            edge.surface,
            surfaceReadingData: surfaceReadingData
        ), surfaceReading != edge.surface {
            return surfaceReading
        }

        if let lemmaReading = readingForSegment(
            preferredLemmaReference,
            surfaceReadingData: surfaceReadingData
        ), lemmaReading != edge.surface, lemmaReading != preferredLemmaReference {
            let isLemmaReadingCompatibleWithSurface = firstKanjiRunReading(in: edge.surface, using: lemmaReading) != nil
            if isLemmaReadingCompatibleWithSurface == false {
                return nil
            }

            return lemmaReading
        }

        return nil
    }

    // Produces kanji-run furigana annotations, including mixed forms with multiple kanji clusters.
    func furiganaAnnotations(
        for segmentSurface: String,
        segmentRange: Range<String.Index>,
        sourceText: String,
        lemmaReference: String,
        surfaceReadingData: SurfaceReadingDataMap
    ) -> [(reading: String, localStartOffset: Int, localLength: Int)] {
        let runs = kanjiRuns(in: segmentSurface)
        guard runs.isEmpty == false else {
            return []
        }

        let furiganaLemmaReference = preferredFuriganaLemmaReference(
            for: segmentSurface,
            lemmaReference: lemmaReference
        )

        if runs.count == 1,
              let lemmaReading = readingForSegment(
                     furiganaLemmaReference,
                     surfaceReadingData: surfaceReadingData
              ),
           let lemmaCoreReading = firstKanjiRunReading(in: furiganaLemmaReference, using: lemmaReading) {
            return [
                (
                    reading: lemmaCoreReading,
                    localStartOffset: runs[0].start,
                    localLength: runs[0].end - runs[0].start
                )
            ]
        }

        let lemmaRuns = kanjiRuns(in: furiganaLemmaReference)
        var projectedReadings: [String]?
        if let lemmaReading = readingForSegment(
            furiganaLemmaReference,
            surfaceReadingData: surfaceReadingData
        ), lemmaRuns.count == runs.count {
            projectedReadings = projectRunReadings(surface: furiganaLemmaReference, reading: lemmaReading)
        }

        if projectedReadings == nil,
           let surfaceReading = readingForSegment(
                segmentSurface,
                surfaceReadingData: surfaceReadingData
           ) {
            projectedReadings = projectRunReadings(surface: segmentSurface, reading: surfaceReading)
        }

        var annotations: [(reading: String, localStartOffset: Int, localLength: Int)] = []
        if let projectedReadings, projectedReadings.count == runs.count {
            for (index, run) in runs.enumerated() {
                let runSurface = String(Array(segmentSurface)[run.start..<run.end])
                let runReading = projectedReadings[index]
                if runReading.isEmpty || runReading == runSurface {
                    continue
                }
                annotations.append((reading: runReading, localStartOffset: run.start, localLength: run.end - run.start))
            }
        }

        if annotations.isEmpty {
            for run in runs {
                let runSurface = String(Array(segmentSurface)[run.start..<run.end])
                guard let runReading = readingForSegment(
                    runSurface,
                    surfaceReadingData: surfaceReadingData
                ), runReading != runSurface else {
                    continue
                }

                // For single-run mixed surfaces (e.g. 私たち) the per-run reading must align
                // with the surrounding kana (たち), otherwise the displayed ruby would contradict
                // the okurigana. Multi-run surfaces (e.g. 抜け殻) have no contradiction risk —
                // each run sits over its own kanji, so any valid per-kanji reading is acceptable
                // and showing the dictionary default beats showing nothing when the compound's
                // own surface reading is unavailable.
                if runs.count == 1,
                   firstKanjiRunReading(in: segmentSurface, using: runReading) == nil {
                    continue
                }

                annotations.append((reading: runReading, localStartOffset: run.start, localLength: run.end - run.start))
            }
        }

        return annotations
    }

    // Recovers a script-preserving lemma so kanji segments still receive furigana when edge lemmas fall back to kana.
    func preferredFuriganaLemmaReference(for segmentSurface: String, lemmaReference: String) -> String {
        guard ScriptClassifier.containsKanji(segmentSurface) else {
            return lemmaReference
        }

        if let preferredLemma = segmenter.preferredLemma(for: segmentSurface) {
            return preferredLemma
        }

        return lemmaReference
    }

    // Splits a surface reading into per-kanji-run readings using kana delimiters from the source surface.
    func projectRunReadings(surface: String, reading: String) -> [String]? {
        let runs = kanjiRuns(in: surface)
        guard runs.isEmpty == false else {
            return nil
        }

        let surfaceCharacters = Array(surface)
        var readingCursor = reading.startIndex

        let prefixSurface = runs[0].start > 0 ? String(surfaceCharacters[0..<runs[0].start]) : ""
        if !prefixSurface.isEmpty, reading[readingCursor...].hasPrefix(prefixSurface) {
            readingCursor = reading.index(readingCursor, offsetBy: prefixSurface.count)
        }

        var runReadings: [String] = []
        for runIndex in runs.indices {
            let run = runs[runIndex]
            let separatorAfterRun: String
            if runIndex + 1 < runs.count {
                separatorAfterRun = String(surfaceCharacters[run.end..<runs[runIndex + 1].start])
            } else {
                separatorAfterRun = run.end < surfaceCharacters.count
                    ? String(surfaceCharacters[run.end..<surfaceCharacters.count])
                    : ""
            }

            if separatorAfterRun.isEmpty {
                let remaining = String(reading[readingCursor...])
                runReadings.append(remaining)
                readingCursor = reading.endIndex
                continue
            }

            // For the last run, trailing okurigana must match the end of the reading.
            // Searching forward risks matching separator characters that appear inside
            // the kanji reading itself (e.g. 占う: "う" in "うらなう" must be the last one).
            if runIndex == runs.count - 1 {
                guard String(reading[readingCursor...]).hasSuffix(separatorAfterRun) else { return nil }
                let tail = reading[readingCursor...]
                let endOffset = tail.index(tail.endIndex, offsetBy: -separatorAfterRun.count)
                runReadings.append(String(tail[tail.startIndex..<endOffset]))
                readingCursor = reading.endIndex
                continue
            }

            guard let separatorRange = reading.range(of: separatorAfterRun, range: readingCursor..<reading.endIndex) else {
                return nil
            }

            let runReading = String(reading[readingCursor..<separatorRange.lowerBound])
            runReadings.append(runReading)
            readingCursor = separatorRange.upperBound
        }

        if readingCursor < reading.endIndex {
            if let last = runReadings.indices.last {
                runReadings[last] += String(reading[readingCursor..<reading.endIndex])
            }
        }

        return runReadings
    }

    // Detects contiguous kanji runs in a surface string and returns character-index ranges.
    // Iteration marks (々) are treated as run continuations when they follow a kanji character.
    func kanjiRuns(in surface: String) -> [(start: Int, end: Int)] {
        let characters = Array(surface)
        var runs: [(start: Int, end: Int)] = []
        var runStart: Int?

        for (index, character) in characters.enumerated() {
            let isKanji = ScriptClassifier.containsKanji(String(character))
            let isIterationMark = character.unicodeScalars.first?.value == 0x3005 // 々
            // Iteration marks extend an active kanji run but cannot start one.
            let continuesRun = isIterationMark && runStart != nil
            if isKanji || continuesRun {
                if runStart == nil {
                    runStart = index
                }
            } else if let currentRunStart = runStart {
                runs.append((start: currentRunStart, end: index))
                runStart = nil
            }
        }

        if let runStart {
            runs.append((start: runStart, end: characters.count))
        }

        return runs
    }

    // Extracts the reading that maps to the first contiguous kanji run of a dictionary surface.
    func firstKanjiRunReading(in surface: String, using reading: String) -> String? {
        let characters = Array(surface)
        let runs = kanjiRuns(in: surface)
        var runStart: Int?
        var runEnd: Int?

        for (index, character) in characters.enumerated() {
            let isKanji = ScriptClassifier.containsKanji(String(character))
            if isKanji {
                if runStart == nil {
                    runStart = index
                }
                runEnd = index + 1
            } else if runStart != nil {
                break
            }
        }

        guard let runStart, let runEnd else {
            return nil
        }

        let allowsIsolatedRunReading = runs.count == 1
        let prefixSurface = String(characters[..<runStart])
        let suffixSurface = runEnd < characters.count
            ? String(characters[runEnd..<characters.count])
            : ""
        var trimmedReading = reading

        if !prefixSurface.isEmpty {
            if hasPhoneticPrefix(trimmedReading, matching: prefixSurface) {
                trimmedReading.removeFirst(prefixSurface.count)
            } else if allowsIsolatedRunReading == false {
                return nil
            }
        }

        if !suffixSurface.isEmpty {
            if hasPhoneticSuffix(trimmedReading, matching: suffixSurface) {
                trimmedReading.removeLast(suffixSurface.count)
            } else if allowsIsolatedRunReading == false {
                return nil
            }
        }

        let kanjiRunSurface = String(characters[runStart..<runEnd])
        guard !trimmedReading.isEmpty, trimmedReading != kanjiRunSurface else {
            return nil
        }

        return trimmedReading
    }

    // Checks a reading prefix against surface okurigana using phonetic-normalized kana matching.
    func hasPhoneticPrefix(_ reading: String, matching surfacePrefix: String) -> Bool {
        guard reading.count >= surfacePrefix.count else {
            return false
        }

        let readingPrefix = String(reading.prefix(surfacePrefix.count))
        return KanaNormalizer.normalizeForFuriganaAlignment(readingPrefix) == KanaNormalizer.normalizeForFuriganaAlignment(surfacePrefix)
    }

    // Checks a reading suffix against surface okurigana using phonetic-normalized kana matching.
    func hasPhoneticSuffix(_ reading: String, matching surfaceSuffix: String) -> Bool {
        guard reading.count >= surfaceSuffix.count else {
            return false
        }

        let readingSuffix = String(reading.suffix(surfaceSuffix.count))
        return KanaNormalizer.normalizeForFuriganaAlignment(readingSuffix) == KanaNormalizer.normalizeForFuriganaAlignment(surfaceSuffix)
    }

    // Looks up the preferred reading for a segment surface from the unified surface reading map.
    func readingForSegment(
        _ segmentSurface: String,
        surfaceReadingData: SurfaceReadingDataMap
    ) -> String? {
        surfaceReadingData[segmentSurface]?.readings.first
    }

    // Applies recompute output to the in-memory furigana maps with replace-on-overlap semantics.
    // A new annotation that strictly contains existing entries (e.g. ものがたり at [L, L+2)
    // covering prior per-character entries もの at [L, L+1) and がたり at [L+1, L+2)) supersedes
    // those fragments — they're removed and the new span is installed. Otherwise backfill is
    // additive: the new entry fills empty locations without overwriting same-range entries
    // (preserving user pins and prior-correct annotations).
    func furiganaAfterApplyingNewAnnotations(
        existingByLocation: [Int: String],
        existingLengthByLocation: [Int: Int],
        newByLocation: [Int: String],
        newLengthByLocation: [Int: Int]
    ) -> (byLocation: [Int: String], lengthByLocation: [Int: Int]) {
        var resultByLocation = existingByLocation
        var resultLengthByLocation = existingLengthByLocation

        for (newLocation, newReading) in newByLocation {
            guard let newLength = newLengthByLocation[newLocation] else {
                // buildFuriganaBySegmentLocation always pairs reading with length — a missing
                // length here means the recompute produced inconsistent output. Skip and warn
                // rather than silently install a degenerate zero-length entry.
                print("furiganaAfterApplyingNewAnnotations: missing length for reading '\(newReading)' at location \(newLocation); skipping")
                continue
            }
            guard newLength > 0 else {
                // Zero-length entries are filtered by buildFuriganaBySegmentLocation at source;
                // reaching here implies corrupted persisted data or a producer bug.
                print("furiganaAfterApplyingNewAnnotations: zero-length entry at location \(newLocation) (reading '\(newReading)'); skipping")
                continue
            }
            let newEnd = newLocation + newLength

            let coveredLocations: [Int] = resultByLocation.keys.filter { existingLocation in
                guard let existingLength = resultLengthByLocation[existingLocation], existingLength > 0 else {
                    return false
                }
                let existingEnd = existingLocation + existingLength
                let isContained = existingLocation >= newLocation && existingEnd <= newEnd
                let isSameRange = existingLocation == newLocation && existingLength == newLength
                return isContained && !isSameRange
            }

            if coveredLocations.isEmpty {
                if resultByLocation[newLocation] == nil {
                    resultByLocation[newLocation] = newReading
                    resultLengthByLocation[newLocation] = newLength
                }
            } else {
                for location in coveredLocations {
                    resultByLocation.removeValue(forKey: location)
                    resultLengthByLocation.removeValue(forKey: location)
                }
                resultByLocation[newLocation] = newReading
                resultLengthByLocation[newLocation] = newLength
            }
        }

        return (byLocation: resultByLocation, lengthByLocation: resultLengthByLocation)
    }

    // Synthesizes a single-span concatenated reading for kanji runs that are tiled by per-
    // character fragments but lack a span-wide annotation. Used after the recompute as a
    // fallback for merged compounds whose surface has no compound reading in surfaceReadingData
    // (e.g. a coined name like 月色): if the prior per-character entries (つき + いろ) cover the
    // merged kanji run without gaps, they're collapsed into one ruby span "つきいろ" over the
    // compound. When a span-wide annotation already exists at the run's range, this is a no-op
    // — the dictionary compound reading always wins over a synthesized concatenation.
    func furiganaAfterSynthesizingCompoundReadings(
        furiganaByLocation: [Int: String],
        furiganaLengthByLocation: [Int: Int],
        edges: [LatticeEdge],
        sourceText: String
    ) -> (byLocation: [Int: String], lengthByLocation: [Int: Int]) {
        var resultByLocation = furiganaByLocation
        var resultLengthByLocation = furiganaLengthByLocation

        for (segmentNSRange, segmentSurface) in segmentNSRangesAndSurfaces(for: edges, in: sourceText) {
            for run in kanjiRuns(in: segmentSurface) {
                guard run.end - run.start > 1 else { continue }
                guard
                    let runStartIdx = segmentSurface.index(
                        segmentSurface.startIndex,
                        offsetBy: run.start,
                        limitedBy: segmentSurface.endIndex
                    ),
                    let runEndIdx = segmentSurface.index(
                        segmentSurface.startIndex,
                        offsetBy: run.end,
                        limitedBy: segmentSurface.endIndex
                    )
                else {
                    continue
                }
                let runRangeInSurface = NSRange(runStartIdx..<runEndIdx, in: segmentSurface)
                let runLocation = segmentNSRange.location + runRangeInSurface.location
                let runLength = runRangeInSurface.length
                let runEnd = runLocation + runLength

                if resultLengthByLocation[runLocation] == runLength {
                    continue
                }

                let entriesInRun = resultByLocation.keys.compactMap { entryLocation -> Int? in
                    guard let entryLength = resultLengthByLocation[entryLocation] else {
                        print("furiganaAfterSynthesizingCompoundReadings: missing length for entry at location \(entryLocation); skipping")
                        return nil
                    }
                    guard entryLength > 0 else {
                        print("furiganaAfterSynthesizingCompoundReadings: zero-length entry at location \(entryLocation); skipping")
                        return nil
                    }
                    guard entryLocation >= runLocation, entryLocation + entryLength <= runEnd else {
                        return nil
                    }
                    return entryLocation
                }.sorted()

                var cursor = runLocation
                var pieces: [String] = []
                var coversFully = true
                for entryLocation in entriesInRun {
                    guard entryLocation == cursor,
                          let entryLength = resultLengthByLocation[entryLocation],
                          entryLength > 0,
                          let entryReading = resultByLocation[entryLocation]
                    else {
                        coversFully = false
                        break
                    }
                    pieces.append(entryReading)
                    cursor = entryLocation + entryLength
                }

                guard coversFully, cursor == runEnd, pieces.count > 1 else { continue }

                for entryLocation in entriesInRun {
                    resultByLocation.removeValue(forKey: entryLocation)
                    resultLengthByLocation.removeValue(forKey: entryLocation)
                }
                resultByLocation[runLocation] = pieces.joined()
                resultLengthByLocation[runLocation] = runLength
            }
        }

        return (byLocation: resultByLocation, lengthByLocation: resultLengthByLocation)
    }
}
