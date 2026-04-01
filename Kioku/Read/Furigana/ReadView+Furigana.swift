import SwiftUI
import UIKit

// Hosts furigana computation and reading selection helpers for the read screen.
extension ReadView {
    // Computes furigana off-main and applies only the latest result for the current editor text.
    func scheduleFuriganaGeneration(for sourceText: String, edges: [LatticeEdge]) {
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
                guard text == sourceText else {
                    return
                }

                StartupTimer.mark("applying furigana result to UI")

                let shouldKeepExistingFurigana = hasKanjiEdges
                    && furiganaResult.furiganaByLocation.isEmpty
                    && furiganaBySegmentLocation.isEmpty == false

                if shouldKeepExistingFurigana {
                    return
                }

                furiganaBySegmentLocation = furiganaResult.furiganaByLocation
                furiganaLengthBySegmentLocation = furiganaResult.lengthByLocation

                // Compact format logging disabled.

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
            let lemmaSurfaceRuns = kanjiRuns(in: furiganaLemmaReference)
            if let lemmaRun = lemmaSurfaceRuns.first {
                let segmentCharacters = Array(segmentSurface)
                let lemmaCharacters = Array(furiganaLemmaReference)

                let segmentSuffix = runs[0].end < segmentCharacters.count
                    ? String(segmentCharacters[runs[0].end..<segmentCharacters.count])
                    : ""
                let lemmaSuffix = lemmaRun.end < lemmaCharacters.count
                    ? String(lemmaCharacters[lemmaRun.end..<lemmaCharacters.count])
                    : ""

                // Avoid attaching full lemma readings when surface adds trailing kana not represented in the lemma.
                if segmentSuffix.isEmpty == false, lemmaSuffix.isEmpty {
                    return []
                }
            }

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

                // Reject per-run fallback readings that do not align with mixed-surface kana affixes.
                if firstKanjiRunReading(in: segmentSurface, using: runReading) == nil {
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

        let prefixSurface = String(characters[..<runStart])
        let suffixSurface = runEnd < characters.count
            ? String(characters[runEnd..<characters.count])
            : ""
        var trimmedReading = reading

        if !prefixSurface.isEmpty {
            guard hasPhoneticPrefix(trimmedReading, matching: prefixSurface) else {
                return nil
            }

            trimmedReading.removeFirst(prefixSurface.count)
        }

        if !suffixSurface.isEmpty {
            guard hasPhoneticSuffix(trimmedReading, matching: suffixSurface) else {
                return nil
            }

            trimmedReading.removeLast(suffixSurface.count)
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
}
