import SwiftUI
import UIKit

// Furigana orchestration on ReadView — schedules computation, applies recompute results to
// in-memory state, and persists segments. The resolution algorithm itself (edge → reading)
// now lives in `FuriganaResolver`; this extension keeps:
//   • the throttle / confirm / cancel pipeline around generation,
//   • the in-memory map merge passes (apply-overlap backfill and compound synthesis),
//   • thin instance-method wrappers so `ReadView+LLMCorrection` and `ReadViewFuriganaTests`
//     can keep calling `kanjiRuns(in:)` / `firstKanjiRunReading` / `buildFuriganaBySegmentLocation`
//     directly on a ReadView.
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

                let migratedSynthesizedLocations = synthesizedFuriganaLocations

                let intermediate: (byLocation: [Int: String], lengthByLocation: [Int: Int], synthesizedLocations: Set<Int>)
                if shouldRunBackfill {
                    // Replace-on-overlap backfill: a new annotation that strictly contains existing
                    // entries (e.g. ものがたり at [L, L+2) covering prior per-character entries from
                    // a pre-merge segmentation of 物 + 語) supersedes those fragments. Otherwise
                    // additive backfill — existing entries at same range are kept (preserves user
                    // pins and prior-correct annotations) and gaps are filled. Same-range
                    // collisions against entries in `migratedSynthesizedLocations` are replaced
                    // by the dict-derived value (recovers disk-poisoned wide entries).
                    intermediate = furiganaAfterApplyingNewAnnotations(
                        existingByLocation: furiganaBySegmentLocation,
                        existingLengthByLocation: furiganaLengthBySegmentLocation,
                        newByLocation: furiganaResult.furiganaByLocation,
                        newLengthByLocation: furiganaResult.lengthByLocation,
                        synthesizedLocations: migratedSynthesizedLocations
                    )
                } else {
                    intermediate = (
                        byLocation: furiganaBySegmentLocation,
                        lengthByLocation: furiganaLengthBySegmentLocation,
                        synthesizedLocations: migratedSynthesizedLocations
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
                let synthesized: (byLocation: [Int: String], lengthByLocation: [Int: Int], synthesizedLocations: Set<Int>)
                if shouldRunBackfill {
                    synthesized = furiganaAfterSynthesizingCompoundReadings(
                        furiganaByLocation: intermediate.byLocation,
                        furiganaLengthByLocation: intermediate.lengthByLocation,
                        edges: segmentEdges,
                        sourceText: sourceText,
                        synthesizedLocations: intermediate.synthesizedLocations
                    )
                } else {
                    synthesized = intermediate
                }
                furiganaBySegmentLocation = synthesized.byLocation
                furiganaLengthBySegmentLocation = synthesized.lengthByLocation
                synthesizedFuriganaLocations = synthesized.synthesizedLocations

                // Persist segments with furigana now that readings are fully resolved.
                rebuildAndPersistSegments(recordRuntime: true)
            }
        }
    }

    // Resolves per-segment furigana keyed by UTF-16 location so UIKit ranges can apply ruby text.
    // Thin wrapper over `FuriganaResolver` kept for two reasons: the tuple-label shape
    // (furiganaByLocation:) matches what `performScheduleFuriganaGeneration` consumes above, and
    // `ReadViewFuriganaTests` calls this entry point directly on a ReadView instance.
    func buildFuriganaBySegmentLocation(
        for sourceText: String,
        edges: [LatticeEdge],
        surfaceReadingData: SurfaceReadingDataMap
    ) -> (furiganaByLocation: [Int: String], lengthByLocation: [Int: Int]) {
        let resolved = FuriganaResolver(segmenter: segmenter).build(
            for: sourceText,
            edges: edges,
            surfaceReadingData: surfaceReadingData
        )
        return (furiganaByLocation: resolved.byLocation, lengthByLocation: resolved.lengthByLocation)
    }

    // Wrapper kept so existing tests (`ReadViewFuriganaTests.testFirstKanjiRunReading*`) keep
    // calling on a ReadView. New callers should use FuriganaResolver directly.
    func firstKanjiRunReading(in surface: String, using reading: String) -> String? {
        FuriganaResolver(segmenter: segmenter).firstKanjiRunReading(in: surface, using: reading)
    }

    // Wrapper kept so `ReadView+LLMCorrection` keeps calling on a ReadView. Delegates to the
    // canonical implementation in `FuriganaAttributedString`.
    func kanjiRuns(in surface: String) -> [(start: Int, end: Int)] {
        FuriganaAttributedString.kanjiRuns(in: surface)
    }

    // Writes per-kanji-run furigana entries for `surface` at UTF-16 `location` using `reading`.
    // First clears any pre-existing entries inside the surface's range so the new run-level
    // entries don't collide with a stale segment-level entry, then projects `reading` over the
    // kanji runs via okurigana alignment and writes one entry per run.
    //
    // Returns true if at least one run-level entry was written. False when projection fails or
    // there are no kanji runs — the caller decides what to do (currently both callers fall back
    // to leaving the location empty, letting the next recompute backfill).
    //
    // Shared by `applyReadingOverride` (user pin via the lookup sheet) and the LLM correction's
    // per-segment reading apply, so the kanji-run projection + stale-clear sequence lives in
    // one place.
    @discardableResult
    func applyPerRunFurigana(surface: String, reading: String, at location: Int) -> Bool {
        let surfaceUTF16Length = surface.utf16.count
        guard surfaceUTF16Length > 0 else { return false }

        // Clear any pre-existing entries whose range overlaps the surface — a stale
        // segment-level entry would otherwise coexist with new per-run entries.
        let segmentNSRange = NSRange(location: location, length: surfaceUTF16Length)
        let staleLocations = Set(furiganaBySegmentLocation.keys.filter { loc in
            let len = furiganaLengthBySegmentLocation[loc] ?? 0
            return NSIntersectionRange(NSRange(location: loc, length: len), segmentNSRange).length > 0
        })
        furiganaBySegmentLocation = furiganaBySegmentLocation.filter { !staleLocations.contains($0.key) }
        furiganaLengthBySegmentLocation = furiganaLengthBySegmentLocation.filter { !staleLocations.contains($0.key) }

        let chars = Array(surface)
        let runs = FuriganaAttributedString.kanjiRuns(in: surface)
        guard runs.isEmpty == false,
              let runReadings = FuriganaAttributedString.normalizedRunReadings(surface: surface, reading: reading, runs: runs),
              runReadings.count == runs.count else {
            return false
        }

        var wroteAny = false
        for (index, run) in runs.enumerated() {
            let runSurface = String(chars[run.start..<run.end])
            let runReading = runReadings[index]
            guard runReading.isEmpty == false, runReading != runSurface else {
                continue
            }
            let prefixUTF16 = String(chars[..<run.start]).utf16.count
            let runLength = String(chars[run.start..<run.end]).utf16.count
            let runLocation = location + prefixUTF16
            furiganaBySegmentLocation[runLocation] = runReading
            furiganaLengthBySegmentLocation[runLocation] = runLength
            wroteAny = true
        }
        return wroteAny
    }

    // Applies recompute output to the in-memory furigana maps with replace-on-overlap semantics.
    // A new annotation that strictly contains existing entries (e.g. ものがたり at [L, L+2)
    // covering prior per-character entries もの at [L, L+1) and がたり at [L+1, L+2)) supersedes
    // those fragments — they're removed and the new span is installed. Otherwise backfill is
    // additive: the new entry fills empty locations without overwriting same-range entries
    // (preserving user pins and prior-correct annotations).
    //
    // The `synthesizedLocations` set carries origin info for wide entries the synthesis pass
    // produced (e.g. ものご concatenated from per-character fragments before resources loaded,
    // then persisted to disk). On a same-range collision, the dict-derived recompute value is
    // allowed to replace a synthesized entry — without this distinction, a poisoned ものご at
    // [L, 2) would block ものがたり at [L, 2) forever via the user-pin preservation rule. Entries
    // absent from the set are treated as user-authored (LLM pin, manual edit) and preserved.
    // Returns the updated set so callers can persist it across recomputes; replaced locations
    // are removed because the new value comes from the dictionary, not synthesis.
    func furiganaAfterApplyingNewAnnotations(
        existingByLocation: [Int: String],
        existingLengthByLocation: [Int: Int],
        newByLocation: [Int: String],
        newLengthByLocation: [Int: Int],
        synthesizedLocations: Set<Int> = []
    ) -> (byLocation: [Int: String], lengthByLocation: [Int: Int], synthesizedLocations: Set<Int>) {
        var resultByLocation = existingByLocation
        var resultLengthByLocation = existingLengthByLocation
        var resultSynthesizedLocations = synthesizedLocations

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
                } else if let existingLength = resultLengthByLocation[newLocation],
                          existingLength == newLength,
                          resultByLocation[newLocation] != newReading,
                          resultSynthesizedLocations.contains(newLocation) {
                    // Same-range collision against a synthesized entry — the dict-derived
                    // compound reading wins. Strip the synthesized marker since the new
                    // value is from the dictionary, not from concatenated fragments.
                    resultByLocation[newLocation] = newReading
                    resultLengthByLocation[newLocation] = newLength
                    resultSynthesizedLocations.remove(newLocation)
                }
            } else {
                for location in coveredLocations {
                    resultByLocation.removeValue(forKey: location)
                    resultLengthByLocation.removeValue(forKey: location)
                    resultSynthesizedLocations.remove(location)
                }
                resultByLocation[newLocation] = newReading
                resultLengthByLocation[newLocation] = newLength
                resultSynthesizedLocations.remove(newLocation)
            }
        }

        return (
            byLocation: resultByLocation,
            lengthByLocation: resultLengthByLocation,
            synthesizedLocations: resultSynthesizedLocations
        )
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
        sourceText: String,
        synthesizedLocations: Set<Int> = []
    ) -> (byLocation: [Int: String], lengthByLocation: [Int: Int], synthesizedLocations: Set<Int>) {
        var resultByLocation = furiganaByLocation
        var resultLengthByLocation = furiganaLengthByLocation
        var resultSynthesizedLocations = synthesizedLocations

        for (segmentNSRange, segmentSurface) in segmentNSRangesAndSurfaces(for: edges, in: sourceText) {
            for run in FuriganaAttributedString.kanjiRuns(in: segmentSurface) {
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
                    resultSynthesizedLocations.remove(entryLocation)
                }
                resultByLocation[runLocation] = pieces.joined()
                resultLengthByLocation[runLocation] = runLength
                // Tag the new wide entry as synthesized so a later recompute with a real
                // dict-derived compound reading can replace it via the apply-on-overlap pass.
                resultSynthesizedLocations.insert(runLocation)
            }
        }

        return (
            byLocation: resultByLocation,
            lengthByLocation: resultLengthByLocation,
            synthesizedLocations: resultSynthesizedLocations
        )
    }
}
