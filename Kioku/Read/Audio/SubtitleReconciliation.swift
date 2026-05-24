import AVFoundation
import Foundation
import SwiftWhisperAlign

// Pure logic for the anchored-reconcile pipeline. Extracted from SubtitleEditorSheet so
// the matching, gap-construction, force-fit, and merge steps can be unit-tested without
// spinning up a SwiftUI view, an aligner, or an AVAsset. The editor keeps the I/O glue
// (slicing audio, calling the aligner, updating @State); this namespace holds only the
// transformations on (cues, note lines, audio duration) tuples.
//
// Pinned by docs/INVARIANTS.md "Alignment & Reconcile" section. Any change here must
// keep the labelled invariants green in SubtitleReconciliationTests.

// One input cue that matched a note line, with the position it matched in the note's line
// sequence. Used to drive gap detection — gaps are runs of note lines between anchored
// positions that no input cue claimed.
struct MatchedAnchor: Equatable {
    let cue: SubtitleCue
    let noteLineIndex: Int
}

// Audio window the aligner should fill, plus the script to feed it. `consumedAnchorIndex`
// is the index (into the input `anchors` array) of the preceding anchor this gap absorbs;
// nil for the head gap. Consumed anchors are removed from the final output — their text
// reappears as the first cue in this window's aligned result, with corrected timing.
struct GapWindow: Equatable {
    let audioStart: Double  // seconds, absolute to the source audio
    let audioEnd: Double    // seconds
    let lines: [String]     // first entry is the consumed anchor's text (when present)
    let consumedAnchorIndex: Int?
}

enum SubtitleReconciliation {

    // INVARIANT (Furigana #1-style provenance, for alignment): matching is monotonic in
    // note-line index. A speech cue is matched to the *first* note line at or after the
    // last matched position whose text agrees, never an earlier line and never a later
    // line if an earlier one would match. This prevents chorus refrains (this codebase's
    // worst case: 月色チャイのん has その物語オーロール four times) from binding to the
    // wrong occurrence and twisting subsequent gap windows.
    //
    // Matching is intentionally conservative: exact equality first, then NFKC +
    // whitespace-strip exact. Never fuzzy — see cueMatchesNoteLine for why.
    static func matchAnchors(speechCues: [SubtitleCue], noteLines: [String]) -> [MatchedAnchor] {
        var anchors: [MatchedAnchor] = []
        var nextNoteIdx = 0
        for cue in speechCues {
            var found: Int? = nil
            for ni in nextNoteIdx..<noteLines.count {
                if cueMatchesNoteLine(cue.text, noteLines[ni]) {
                    found = ni
                    break
                }
            }
            if let i = found {
                anchors.append(MatchedAnchor(cue: cue, noteLineIndex: i))
                nextNoteIdx = i + 1
            }
            // Unmatched cues are dropped — the gap alignment that covers their window
            // produces the replacement cue(s). Keeping the unmatched cue would orphan
            // its text (which doesn't appear in the note) inside the new SRT.
        }
        return anchors
    }

    // Predicate for the matching pass. Exact match first, then normalized exact (NFKC
    // composition + whitespace removal). Deliberately not fuzzy — substring or
    // edit-distance matches collide with chorus refrains and the resulting
    // out-of-order assignment cascades into completely wrong gap windows. "Give up"
    // (no match) degrades to an unanchored window, which re-aligns over a larger span;
    // a wrong match poisons everything downstream.
    static func cueMatchesNoteLine(_ cueText: String, _ noteLine: String) -> Bool {
        if cueText == noteLine { return true }
        let normalize: (String) -> String = { s in
            (s as NSString).precomposedStringWithCompatibilityMapping
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
        }
        return normalize(cueText) == normalize(noteLine)
    }

    // Constructs the gap windows the aligner needs to fill. Each gap consumes its
    // preceding anchor (audio range and script both include it) so the aligner can
    // discover where the anchor's text actually ends in the audio — the source-aligner
    // failure mode is a cue whose end-time is too late because it swallowed the audio
    // of the missing lines. Head gap has no preceding anchor; tail gap consumes the
    // last anchor.
    //
    // INVARIANT (Alignment #4 — idempotence): when every note line is matched by an
    // anchor and the anchor positions are tight (no missing line indices), this
    // returns an empty array. The caller treats that as "nothing to reconcile."
    static func buildGapWindows(
        anchors: [MatchedAnchor],
        noteLines: [String],
        audioDurationSeconds: Double
    ) -> [GapWindow] {
        var gaps: [GapWindow] = []

        // Head: lines before the first anchor.
        let firstAnchorNoteIdx = anchors.first?.noteLineIndex ?? noteLines.count
        if firstAnchorNoteIdx > 0 {
            let audioEnd = anchors.first.map { Double($0.cue.startMs) / 1000.0 } ?? audioDurationSeconds
            gaps.append(GapWindow(
                audioStart: 0,
                audioEnd: audioEnd,
                lines: Array(noteLines[0..<firstAnchorNoteIdx]),
                consumedAnchorIndex: nil
            ))
        }

        // Middle: each consecutive anchor pair with skipped note lines becomes one gap
        // window that *includes* the preceding anchor in both audio range and script.
        for i in 0..<max(0, anchors.count - 1) {
            let here = anchors[i]
            let next = anchors[i + 1]
            if next.noteLineIndex > here.noteLineIndex + 1 {
                gaps.append(GapWindow(
                    audioStart: Double(here.cue.startMs) / 1000.0,
                    audioEnd: Double(next.cue.startMs) / 1000.0,
                    lines: [here.cue.text] + Array(noteLines[(here.noteLineIndex + 1)..<next.noteLineIndex]),
                    consumedAnchorIndex: i
                ))
            }
        }

        // Tail: lines after the last anchor. Consumes the last anchor.
        if let lastIdx = anchors.indices.last, anchors[lastIdx].noteLineIndex < noteLines.count - 1 {
            let last = anchors[lastIdx]
            gaps.append(GapWindow(
                audioStart: Double(last.cue.startMs) / 1000.0,
                audioEnd: audioDurationSeconds,
                lines: [last.cue.text] + Array(noteLines[(last.noteLineIndex + 1)..<noteLines.count]),
                consumedAnchorIndex: lastIdx
            ))
        }

        return gaps
    }

    // Force-fit fallback when the aligner couldn't produce one cue per input line.
    // Distributes lines uniformly across the gap's millisecond span so every note line
    // lands somewhere in the window. Cue durations are the slice length; the user can
    // refine by hand and re-run reconcile once surrounding anchors improve.
    //
    // INVARIANT (Alignment #5 — force-fit completeness): the returned cue count
    // exactly equals `lines.count`; the first cue starts at `windowStartMs`; the last
    // cue ends at `windowEndMs`.
    static func uniformDistribute(
        lines: [String],
        windowStartMs: Int,
        windowEndMs: Int
    ) -> [SubtitleCue] {
        guard lines.isEmpty == false else { return [] }
        let totalDurationMs = max(0, windowEndMs - windowStartMs)
        let per = max(1, totalDurationMs / lines.count)
        return lines.enumerated().map { i, line in
            let start = windowStartMs + i * per
            let end = (i == lines.count - 1) ? windowEndMs : windowStartMs + (i + 1) * per
            return SubtitleCue(index: 0, startMs: start, endMs: end, text: line)
        }
    }

    // Reads the duration of an audio file via AVAsset's async loader. nil when the load
    // fails or the asset has no audio tracks — callers fail the reconcile gracefully.
    static func audioDurationSeconds(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            return nil
        }
    }

    // Extracts an audio range to a temp .m4a via AVAssetExportSession. The exported file
    // lives in /tmp and is cleaned up by the caller's defer block. Used to feed the
    // forced aligner a small clip per gap so it can run cleanly against just that window
    // without re-encountering the audio it has already anchored.
    static func sliceAudio(audioURL: URL, from: Double, to: Double) async throws -> URL {
        let asset = AVURLAsset(url: audioURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(
                domain: "Kioku.Reconcile",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't create exporter for audio slice."]
            )
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("kioku-reconcile-\(UUID().uuidString).m4a")
        exporter.outputURL = tempURL
        exporter.outputFileType = .m4a
        let timescale: CMTimeScale = 1000
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: from, preferredTimescale: timescale),
            end: CMTime(seconds: to, preferredTimescale: timescale)
        )

        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(
                domain: "Kioku.Reconcile",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Audio slice export failed."]
            )
        }
        return tempURL
    }

    // End-to-end anchored reconcile: takes (audio, current cues, note lines, model),
    // produces the merged output cues. This is what `reconcileFromNote` calls in the
    // editor sheet and what AlignmentQualityTests measures — keeping it in one place
    // means production and test both exercise the same pipeline. The caller is
    // responsible for SRT formatting, error display, @State plumbing, and progress UI.
    //
    // Algorithm:
    //   1. Match current speech cues to note line positions (monotonic).
    //   2. Build gap windows; each middle/tail gap consumes its preceding anchor so
    //      the aligner can correct any swallowed audio in that anchor.
    //   3. For each gap, slice the audio range to a temp clip and run forced
    //      alignment with the gap's lines as script.
    //   4. Force-fit fallback if the aligner returns fewer cues than expected
    //      (uniform distribution across the window — never drops a line).
    //   5. Merge kept anchors + preserved ♪ cues + gap output; sort + renumber.
    static func reconcile(
        audioURL: URL,
        currentCues: [SubtitleCue],
        noteLines: [String],
        modelURL: URL,
        cancellationCheck: (() -> Bool)? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> [SubtitleCue] {
        let musicCues = currentCues.filter { SubtitleParser.isNonSpeechCue($0.text) }
        let speechCues = currentCues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }
        let anchors = matchAnchors(speechCues: speechCues, noteLines: noteLines)

        onProgress?("Measuring audio…")
        guard let audioDuration = await audioDurationSeconds(for: audioURL), audioDuration > 0 else {
            throw NSError(domain: "Kioku.Reconcile", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't read audio duration."
            ])
        }

        let gaps = buildGapWindows(
            anchors: anchors,
            noteLines: noteLines,
            audioDurationSeconds: audioDuration
        )

        // No gaps means every note line already has a matching anchor — caller treats
        // this as "nothing to reconcile" rather than throw.
        if gaps.isEmpty {
            let consumedAnchorIndices: Set<Int> = []
            return mergeReconciledCues(
                anchors: anchors,
                consumedAnchorIndices: consumedAnchorIndices,
                musicCues: musicCues,
                newGapCues: []
            )
        }

        var newCues: [SubtitleCue] = []
        let runStartedAt = Date()

        for (gapIdx, gap) in gaps.enumerated() {
            if cancellationCheck?() == true {
                throw CancellationError()
            }
            let elapsed = Int(Date().timeIntervalSince(runStartedAt))
            onProgress?("Aligning gap \(gapIdx + 1)/\(gaps.count) · \(gap.lines.count) line\(gap.lines.count == 1 ? "" : "s") · \(elapsed)s")

            let sliceURL = try await sliceAudio(audioURL: audioURL, from: gap.audioStart, to: gap.audioEnd)
            defer { try? FileManager.default.removeItem(at: sliceURL) }

            let lyrics = gap.lines.joined(separator: "\n")
            let alignedCues: [SubtitleCue]
            do {
                let srt = try await OnDeviceLyricAligner.align(
                    audioURL: sliceURL,
                    lyrics: lyrics,
                    modelURL: modelURL,
                    cancellationCheck: { cancellationCheck?() == true }
                )
                alignedCues = SubtitleParser.parse(srt)
            } catch {
                if cancellationCheck?() == true { throw CancellationError() }
                // Per the no-drop invariant: an aligner failure on one gap falls back
                // to uniform distribution rather than abandoning the run.
                print("[Reconcile] gap \(gapIdx + 1) alignment failed (\(error.localizedDescription)); force-fitting")
                alignedCues = []
            }

            let gapSpeechCues = alignedCues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }
            let gapMusicCues = alignedCues.filter { SubtitleParser.isNonSpeechCue($0.text) }
            // Aligner output is trusted only if (a) it produced the expected line
            // count AND (b) all cues are bounded by the window. Whisper occasionally
            // emits timestamps past the audio clip's actual length (segment-boundary
            // hallucination); without the window-bound check, the merge step
            // interleaves these stray cues with the *next* anchor's timing —
            // producing out-of-order output that looks identical to a dropped line
            // in any downstream consumer that walks monotonically (karaoke
            // highlighting, the quality-test matcher).
            let windowDurationMs = Int((gap.audioEnd - gap.audioStart) * 1000)
            let anyCueExceedsWindow = gapSpeechCues.contains { $0.startMs >= windowDurationMs || $0.endMs > windowDurationMs }
            let speechToUse: [SubtitleCue]
            if gapSpeechCues.count == gap.lines.count && anyCueExceedsWindow == false {
                speechToUse = gapSpeechCues
            } else {
                speechToUse = uniformDistribute(
                    lines: gap.lines,
                    windowStartMs: 0,
                    windowEndMs: windowDurationMs
                )
            }

            let offsetMs = Int(gap.audioStart * 1000)
            let absoluteCues = (speechToUse + gapMusicCues).map { cue -> SubtitleCue in
                var copy = cue
                copy.startMs += offsetMs
                copy.endMs += offsetMs
                return copy
            }
            newCues.append(contentsOf: absoluteCues)
        }

        let consumedAnchorIndices: Set<Int> = Set(gaps.compactMap { $0.consumedAnchorIndex })
        return mergeReconciledCues(
            anchors: anchors,
            consumedAnchorIndices: consumedAnchorIndices,
            musicCues: musicCues,
            newGapCues: newCues
        )
    }

    // Combines kept anchors (those not consumed by any gap), preserved ♪ cues, and the
    // aligner's output for each gap. Sorts by start time and renumbers indices so the
    // result is a valid SRT.
    //
    // INVARIANTS:
    //   #3 anchor non-disturbance — anchors not in `consumedAnchorIndices` appear in
    //      the output with identical start/end timings.
    //   #6 music preservation — every cue in `musicCues` appears in the output
    //      unchanged.
    //   #7 anchor consumption contiguous — anchors in `consumedAnchorIndices` do NOT
    //      appear in the output; their text reappears via newGapCues (which the caller
    //      sourced from the aligner's per-gap output).
    static func mergeReconciledCues(
        anchors: [MatchedAnchor],
        consumedAnchorIndices: Set<Int>,
        musicCues: [SubtitleCue],
        newGapCues: [SubtitleCue]
    ) -> [SubtitleCue] {
        let keptAnchorCues: [SubtitleCue] = anchors.enumerated().compactMap { (idx, anchor) in
            consumedAnchorIndices.contains(idx) ? nil : anchor.cue
        }
        var merged: [SubtitleCue] = keptAnchorCues + musicCues + newGapCues
        merged.sort { $0.startMs < $1.startMs }
        for i in 0..<merged.count { merged[i].index = i + 1 }
        return merged
    }
}
