import Foundation

// Resolves per-segment furigana annotations keyed by UTF-16 location, given a segmentation
// edge list and the precomputed surface→reading map. Extracted from `extension ReadView` in
// `ReadView+Furigana.swift` so callers outside ReadView (Songs breakdown, future surfaces)
// can produce the same shape data the renderer consumes without re-implementing the lemma
// fallback / okurigana cropping / fallback-reading logic.
//
// The split with `FuriganaAttributedString`: that enum owns surface↔reading projection
// (kanjiRuns, projectRunReadings, hasPhoneticPrefix/Suffix). This struct owns segment-edge
// resolution: walking edges, picking lemma references, choosing fallback readings when the
// per-run projection fails.
//
// Pure value type. Threadsafe under the segmenter's existing concurrency contract.
struct FuriganaResolver {
    let segmenter: any TextSegmenting

    // Produces the renderer-shape data for a fully segmented source string. Iterates the
    // edge list and, for each kanji-bearing edge, attaches per-run readings or a single
    // fallback reading covering the kanji run.
    func build(
        for sourceText: String,
        edges: [LatticeEdge],
        surfaceReadingData: SurfaceReadingDataMap
    ) -> (byLocation: [Int: String], lengthByLocation: [Int: Int]) {
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
            // Preserve the original ReadView pipeline's early-continue semantics: when run-level
            // projection produced no annotations, skip the fallback path entirely rather than
            // letting `fallbackSegmentFuriganaReading` paint a span-wide reading that the original
            // would never have produced. Behavioural parity with `buildFuriganaBySegmentLocation`
            // pre-extraction is the contract we're holding to.
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
            if FuriganaResolver.segmentHasAttachedFurigana(
                segmentNSRange: segmentNSRange,
                furiganaByLocation: resolvedFurigana,
                lengthByLocation: resolvedFuriganaLengths
            ) == false,
               let fallbackReading = fallbackSegmentFuriganaReading(
                for: edge,
                surfaceReadingData: surfaceReadingData,
                sourceText: sourceText
               ) {
                // For a single-run kanji segment, place the cropped ruby exactly over the kanji
                // sub-range so it doesn't get stretched across okurigana the reading no longer
                // contains. For multi-run / non-kanji-prefix segments, fall back to segment-span
                // placement.
                let segChars = Array(edge.surface)
                let runs = FuriganaAttributedString.kanjiRuns(in: edge.surface)
                if runs.count == 1, runs[0].end <= segChars.count {
                    let run = runs[0]
                    let prefixUTF16 = String(segChars[..<run.start]).utf16.count
                    let runUTF16 = String(segChars[run.start..<run.end]).utf16.count
                    let runLocation = segmentNSRange.location + prefixUTF16
                    resolvedFurigana[runLocation] = fallbackReading
                    resolvedFuriganaLengths[runLocation] = runUTF16
                } else {
                    resolvedFurigana[segmentNSRange.location] = fallbackReading
                    resolvedFuriganaLengths[segmentNSRange.location] = segmentNSRange.length
                }
            }
        }

        return (byLocation: resolvedFurigana, lengthByLocation: resolvedFuriganaLengths)
    }

    // Extracts the reading that maps to the first contiguous kanji run of a dictionary
    // surface. Internal access so the ReadView extension wrapper (kept for test
    // compatibility) and the LLM correction path can both call through here.
    func firstKanjiRunReading(in surface: String, using reading: String) -> String? {
        let characters = Array(surface)
        let runs = FuriganaAttributedString.kanjiRuns(in: surface)
        guard let firstRun = runs.first else {
            return nil
        }
        let runStart = firstRun.start
        let runEnd = firstRun.end

        let allowsIsolatedRunReading = runs.count == 1
        let prefixSurface = String(characters[..<runStart])
        let suffixSurface = runEnd < characters.count
            ? String(characters[runEnd..<characters.count])
            : ""
        var trimmedReading = reading

        if !prefixSurface.isEmpty {
            if FuriganaResolver.hasPhoneticPrefix(trimmedReading, matching: prefixSurface) {
                trimmedReading.removeFirst(prefixSurface.count)
            } else if allowsIsolatedRunReading == false {
                return nil
            }
        }

        if !suffixSurface.isEmpty {
            if FuriganaResolver.hasPhoneticSuffix(trimmedReading, matching: suffixSurface) {
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

    // Verifies that a kanji-bearing segment has at least one ruby annotation overlapping
    // its range. Pure function; static so callers don't need a resolver instance.
    static func segmentHasAttachedFurigana(
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

    // Looks up the preferred reading for a segment surface from the unified surface reading
    // map. Static so it composes cleanly inside the resolver and from callers that just need
    // a one-shot lookup.
    static func readingForSegment(
        _ segmentSurface: String,
        surfaceReadingData: SurfaceReadingDataMap
    ) -> String? {
        surfaceReadingData[segmentSurface]?.readings.first
    }

    // Produces kanji-run furigana annotations, including mixed forms with multiple kanji
    // clusters. The "annotation" tuple lives here rather than as a struct because it has
    // exactly one call site (the build loop above) and a struct would be ceremony.
    private func furiganaAnnotations(
        for segmentSurface: String,
        segmentRange: Range<String.Index>,
        sourceText: String,
        lemmaReference: String,
        surfaceReadingData: SurfaceReadingDataMap
    ) -> [(reading: String, localStartOffset: Int, localLength: Int)] {
        let runs = FuriganaAttributedString.kanjiRuns(in: segmentSurface)
        guard runs.isEmpty == false else {
            return []
        }

        let furiganaLemmaReference = preferredFuriganaLemmaReference(
            for: segmentSurface,
            lemmaReference: lemmaReference
        )

        if runs.count == 1,
              let lemmaReading = FuriganaResolver.readingForSegment(
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

        let lemmaRuns = FuriganaAttributedString.kanjiRuns(in: furiganaLemmaReference)
        var projectedReadings: [String]?
        if let lemmaReading = FuriganaResolver.readingForSegment(
            furiganaLemmaReference,
            surfaceReadingData: surfaceReadingData
        ), lemmaRuns.count == runs.count {
            projectedReadings = FuriganaAttributedString.projectRunReadings(surface: furiganaLemmaReference, reading: lemmaReading)
        }

        if projectedReadings == nil,
           let surfaceReading = FuriganaResolver.readingForSegment(
                segmentSurface,
                surfaceReadingData: surfaceReadingData
           ) {
            projectedReadings = FuriganaAttributedString.projectRunReadings(surface: segmentSurface, reading: surfaceReading)
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
                guard let runReading = FuriganaResolver.readingForSegment(
                    runSurface,
                    surfaceReadingData: surfaceReadingData
                ), runReading != runSurface else {
                    continue
                }

                // For single-run mixed surfaces (e.g. 私たち) the per-run reading must align
                // with the surrounding kana (たち), otherwise the displayed ruby would
                // contradict the okurigana. Multi-run surfaces have no contradiction risk.
                if runs.count == 1,
                   firstKanjiRunReading(in: segmentSurface, using: runReading) == nil {
                    continue
                }

                annotations.append((reading: runReading, localStartOffset: run.start, localLength: run.end - run.start))
            }
        }

        return annotations
    }

    // Recovers a script-preserving lemma so kanji segments still receive furigana when edge
    // lemmas fall back to kana.
    private func preferredFuriganaLemmaReference(for segmentSurface: String, lemmaReference: String) -> String {
        guard ScriptClassifier.containsKanji(segmentSurface) else {
            return lemmaReference
        }

        if let preferredLemma = segmenter.preferredLemma(for: segmentSurface) {
            return preferredLemma
        }

        return lemmaReference
    }

    // Synthesizes a kanji-only fallback reading when run-level furigana alignment fails.
    // The cropping logic — using the lemma's own structure to align reading suffixes — is
    // preserved verbatim from the original ReadView implementation; the comment from there
    // documents why the lemma (not the surface) drives the crop.
    private func fallbackSegmentFuriganaReading(
        for edge: LatticeEdge,
        surfaceReadingData: SurfaceReadingDataMap,
        sourceText: String
    ) -> String? {
        let preferredLemmaReference = preferredFuriganaLemmaReference(
            for: edge.surface,
            lemmaReference: segmenter.preferredLemma(for: edge.surface) ?? edge.surface
        )

        if let surfaceReading = FuriganaResolver.readingForSegment(
            edge.surface,
            surfaceReadingData: surfaceReadingData
        ), surfaceReading != edge.surface {
            if let cropped = firstKanjiRunReading(in: edge.surface, using: surfaceReading) {
                return cropped
            }
            return surfaceReading
        }

        if let lemmaReading = FuriganaResolver.readingForSegment(
            preferredLemmaReference,
            surfaceReadingData: surfaceReadingData
        ), lemmaReading != edge.surface, lemmaReading != preferredLemmaReference {
            let isLemmaReadingCompatibleWithSurface = firstKanjiRunReading(in: edge.surface, using: lemmaReading) != nil
            if isLemmaReadingCompatibleWithSurface == false {
                return nil
            }

            // Crop using the LEMMA's structure (its okurigana aligns to its reading suffix),
            // not the surface's (whose okurigana is inflected and diverges from the reading).
            if let cropped = firstKanjiRunReading(in: preferredLemmaReference, using: lemmaReading) {
                return cropped
            }

            return lemmaReading
        }

        return nil
    }

    // Checks a reading prefix against surface okurigana using phonetic-normalized kana matching.
    private static func hasPhoneticPrefix(_ reading: String, matching surfacePrefix: String) -> Bool {
        guard reading.count >= surfacePrefix.count else {
            return false
        }
        let readingPrefix = String(reading.prefix(surfacePrefix.count))
        return KanaNormalizer.normalizeForFuriganaAlignment(readingPrefix) == KanaNormalizer.normalizeForFuriganaAlignment(surfacePrefix)
    }

    // Checks a reading suffix against surface okurigana using phonetic-normalized kana matching.
    private static func hasPhoneticSuffix(_ reading: String, matching surfaceSuffix: String) -> Bool {
        guard reading.count >= surfaceSuffix.count else {
            return false
        }
        let readingSuffix = String(reading.suffix(surfaceSuffix.count))
        return KanaNormalizer.normalizeForFuriganaAlignment(readingSuffix) == KanaNormalizer.normalizeForFuriganaAlignment(surfaceSuffix)
    }
}
