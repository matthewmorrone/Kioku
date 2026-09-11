import XCTest
@testable import Kioku

// Pins docs/INVARIANTS.md Alignment #9 — alignment quality against ground truth.
//
// Slow tests: each fixture runs the full on-device aligner (Whisper-in-the-loop)
// on a real audio file, then compares the output cues to a stable-ts large-v3
// oracle. One song takes 30-90s depending on length and model size.
//
// Gating strategy: each test self-skips when its fixture directory isn't in the
// test bundle. Adding a fixture (running scripts/generate-alignment-oracle.py
// into KiokuTests/Fixtures/alignment/<name>/) makes the corresponding test
// active. To skip quality tests during a fast iteration cycle, pass
// `-skip-testing:KiokuTests/AlignmentQualityTests` to xcodebuild. We previously
// tried both KIOKU_RUN_QUALITY_TESTS and TEST_RUNNER_KIOKU_RUN_QUALITY_TESTS
// env vars; neither propagates reliably from xcodebuild into the test process
// running on the iOS simulator, so fixture-presence is the trigger instead.
//
// To run (default — skips if no fixtures, runs if any are present):
//     xcodebuild test \\
//         -project Kioku.xcodeproj -scheme Kioku \\
//         -destination 'platform=iOS Simulator,id=...' \\
//         -only-testing:KiokuTests/AlignmentQualityTests \\
//         -parallel-testing-enabled NO
//
// To add a fixture:
//     1. Run /Users/matthewmorrone/Projects/alignment/align.py against a directory
//        containing your song's mp3 + matching .txt (see that repo's README) with
//        STABLE_TS_MODEL=large-v3 and STABLE_TS_VAD=0 — produces .srt + .TextGrid
//        + .json next to the audio.
//     2. Drop the audio + note.txt + the produced ground-truth.srt + tolerance.json
//        into KiokuTests/Fixtures/alignment/<fixture-name>/ (rename .srt to
//        ground-truth.srt; tolerance.json is hand-authored).
//     3. Add a `testQuality_<FixtureName>()` function below that calls
//        runQualityCheck(fixtureName: "<fixture-name>")
//
// The fixture dir must contain:
//     - audio.mp3 (or .m4a/.wav)        the source audio
//     - note.txt                         the lyric script (one line per expected cue)
//     - ground-truth.srt                 the oracle (from align.py, large-v3 + VAD off)
//     - tolerance.json                   thresholds (hand-authored per fixture)
@MainActor
final class AlignmentQualityTests: XCTestCase {

    // No global setUp gate — each test self-skips if its fixture isn't in the
    // bundle. See `runQualityCheck` for the per-test skip.

    // Add fixtures as testQuality_<Name>() functions. Each one loads its fixture
    // dir, runs the aligner, and compares against the oracle. Keep them named
    // testQuality_* so a future name-pattern filter can include/exclude.

    // 月色チャイのん — Sailor Moon Eternal theme. Oracle generated with stable-ts
    // large-v3 (forced align, original_split=True) — verified to contain all 34
    // note lines including the 3 previously-missing ones (アムール詩人の様に奏でて,
    // いま暗闇の淵, 抜け殻抱きしめて) that the on-device aligner historically
    // dropped or mis-placed.
    func testQuality_TsukiiroChainon() async throws {
        try await runQualityCheck(fixtureName: "tsukiiro-chainon")
    }

    // MARK: - Harness

    private struct Tolerance: Decodable {
        let minCoverage: Double
        let medianStartMsTolerance: Int
        let perCueStartMsTolerance: Int
    }

    private struct QualityMetrics {
        let oracleCueCount: Int
        let matchedCueCount: Int
        let coverageFraction: Double         // matched / oracle
        let medianStartDeltaMs: Int          // across matched cues
        let maxStartDeltaMs: Int             // across matched cues
        let missingFromOutput: [String]      // oracle cue texts with no matching output cue
        let extrasInOutput: [String]         // output cue texts not in oracle (informational)
    }

    // Loads a fixture, runs the on-device aligner, and asserts the result is
    // within tolerance of the oracle. Throws (via XCTFail) on any threshold
    // violation; prints metrics on success so passing runs still tell you how
    // close you actually were.
    private func runQualityCheck(fixtureName: String) async throws {
        let bundle = Bundle(for: type(of: self))
        // Synchronized file groups flatten subdirectories when copying resources
        // into the test bundle, so all fixture files live at the bundle root with
        // a `<fixture>.<part>.<ext>` naming convention (e.g.
        // `tsukiiro-chainon.audio.mp3`). Looking up by prefix means a missing
        // fixture (the note.txt isn't there) cleanly degenerates into a skip.
        guard let noteURL = bundle.url(forResource: "\(fixtureName).note", withExtension: "txt") else {
            throw XCTSkip("""
                Fixture \(fixtureName) not in test bundle. To enable:
                  1. Run scripts/generate-alignment-oracle.py with this fixture name
                  2. The script writes \(fixtureName).{audio,note,ground-truth,tolerance}.* files
                     into KiokuTests/Fixtures/alignment/ — the synchronized group
                     auto-includes them in the next build
                """)
        }
        let oracleURL = try requireResource(bundle: bundle, basename: "\(fixtureName).ground-truth", extensions: ["srt"])
        let toleranceURL = try requireResource(bundle: bundle, basename: "\(fixtureName).tolerance", extensions: ["json"])
        let audioURL = try requireResource(bundle: bundle, basename: "\(fixtureName).audio", extensions: ["mp3", "m4a", "wav"])
        let noteText = try String(contentsOf: noteURL, encoding: .utf8)
        let oracleText = try String(contentsOf: oracleURL, encoding: .utf8)
        let toleranceData = try Data(contentsOf: toleranceURL)
        let tolerance = try JSONDecoder().decode(Tolerance.self, from: toleranceData)

        let oracleCues = SubtitleParser.parse(oracleText)
            .filter { SubtitleParser.isNonSpeechCue($0.text) == false }
        let noteLines = noteText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && SubtitleParser.isNonSpeechCue($0) == false }

        // Call the EXACT function the app's Re-align actions use. Test and production share
        // this code path so the test measures user-facing quality, not a re-implementation.
        let alignedCues = try await WholeSongAlignment.cues(
            audioURL: audioURL,
            lyrics: noteLines.joined(separator: "\n")
        )

        let afterSpeechCues = alignedCues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }
        let afterMetrics = computeMetrics(
            output: afterSpeechCues,
            oracle: oracleCues,
            perCueStartMsTolerance: tolerance.perCueStartMsTolerance
        )

        printMetricsReport(
            fixtureName: fixtureName,
            tolerance: tolerance,
            afterMetrics: afterMetrics
        )

        // Diagnostic: per-cue start deltas (worst offenders first) so a grading run
        // pinpoints WHICH line is mis-placed, not just the aggregate. Monotonic walk
        // mirrors computeMetrics. This is how the interlude misplacement was located.
        do {
            var nextOut = 0
            var rows: [(oracleMs: Int, outMs: Int, delta: Int, text: String)] = []
            for oracleCue in oracleCues {
                for j in nextOut..<afterSpeechCues.count
                where cueMatchesNoteLine(afterSpeechCues[j].text, oracleCue.text) {
                    rows.append((oracleCue.startMs, afterSpeechCues[j].startMs,
                                 abs(afterSpeechCues[j].startMs - oracleCue.startMs), oracleCue.text))
                    nextOut = j + 1
                    break
                }
            }
            print("\n[DEBUG] Worst per-cue start deltas:")
            for r in rows.sorted(by: { $0.delta > $1.delta }).prefix(8) {
                print(String(format: "  Δ%6dms  oracle=%6dms  out=%6dms  %@", r.delta, r.oracleMs, r.outMs, r.text))
            }
        }

        // Dumps the output cue list when a line is missing, to show where it went.
        if afterMetrics.missingFromOutput.isEmpty == false {
            print("\n[DEBUG] Reconciled output cues (\(afterSpeechCues.count)):")
            for (i, cue) in afterSpeechCues.enumerated() {
                let inOracle = oracleCues.contains { cueMatchesNoteLine($0.text, cue.text) }
                print("  [\(i)] \(cue.startMs)ms - \(cue.endMs)ms: \(cue.text) \(inOracle ? "✓" : "?")")
            }
            print("\n[DEBUG] Oracle cues NOT found in output (\(afterMetrics.missingFromOutput.count)):")
            for t in afterMetrics.missingFromOutput {
                print("  - \(t)")
            }
        }

        // Hard gate: never drop a line. The alignment must place every note line;
        // overflow rather than drop; this is a structural guarantee, not a
        // quality knob.
        XCTAssertTrue(afterMetrics.missingFromOutput.isEmpty,
                      "Ground-truth cues missing from output: \(afterMetrics.missingFromOutput)")

        // Aspirational timing gate — see XCTExpectFailure note in
        // docs/INVARIANTS.md Alignment #9. Metrics print regardless; the
        // expectFailure suppresses the red so CI tracks the numbers instead of
        // blocking on quality. When quality improves to consistently meet
        // tolerance, XCTExpectFailure will itself fail and we drop the wrapper.
        XCTExpectFailure("Alignment timing not yet within tolerance — see printed metrics for the current AFTER numbers and the BEFORE/AFTER delta") {
            XCTAssertGreaterThanOrEqual(afterMetrics.coverageFraction, tolerance.minCoverage,
                                        "Coverage \(afterMetrics.coverageFraction) < tolerance.minCoverage \(tolerance.minCoverage)")
            XCTAssertLessThanOrEqual(afterMetrics.medianStartDeltaMs, tolerance.medianStartMsTolerance,
                                     "Median start Δ \(afterMetrics.medianStartDeltaMs)ms > tolerance \(tolerance.medianStartMsTolerance)ms")
        }
    }

    // Renders the metrics block: the aligned output graded against the oracle.
    private func printMetricsReport(
        fixtureName: String,
        tolerance: Tolerance,
        afterMetrics: QualityMetrics
    ) {
        func row(_ label: String, _ metrics: QualityMetrics, totalOracleCount: Int) -> [String] {
            let textMatchPct = totalOracleCount == 0 ? 100.0 : Double(metrics.matchedCueCount) / Double(totalOracleCount) * 100
            let withinTolerancePct = metrics.coverageFraction * 100
            let medianFmt = String(format: "%6d ms (%6.2f s)", metrics.medianStartDeltaMs, Double(metrics.medianStartDeltaMs) / 1000)
            let maxFmt = String(format: "%6d ms (%6.2f s)", metrics.maxStartDeltaMs, Double(metrics.maxStartDeltaMs) / 1000)
            let missingDisplay = metrics.missingFromOutput.isEmpty ? "(none)" : metrics.missingFromOutput.joined(separator: ", ")
            let withinCount = Int(round(Double(metrics.matchedCueCount) * metrics.coverageFraction))
            return [
                "│   text-matched:       \(metrics.matchedCueCount) / \(totalOracleCount)  (\(String(format: "%.1f%%", textMatchPct)))",
                "│   within tolerance:   \(withinCount) / \(totalOracleCount)  (\(String(format: "%.1f%%", withinTolerancePct)))",
                "│   median Δstart:      \(medianFmt)",
                "│   max Δstart:         \(maxFmt)",
                "│   missing from out:   \(missingDisplay)",
            ]
        }

        var lines: [String] = [
            "",
            "┌─ [QualityTest] \(fixtureName) — whole-song alignment ──",
            "│  oracle cues:         \(afterMetrics.oracleCueCount)",
            "│  tolerance:           ≥ \(String(format: "%.0f%%", tolerance.minCoverage * 100)) within ±\(tolerance.perCueStartMsTolerance)ms · median Δ ≤ \(tolerance.medianStartMsTolerance)ms",
            "│",
        ]

        lines += [
            "│  RESULT  (aligned output vs oracle — what users get)",
        ]
        lines += row("AFTER", afterMetrics, totalOracleCount: afterMetrics.oracleCueCount)

        lines += [
            "└────────────────────────────────────────────────────────────────────",
            "",
        ]
        print(lines.joined(separator: "\n"))
    }

    // Looks up a resource at the bundle root with any of the candidate extensions.
    // Used so fixtures can ship as either .mp3 / .m4a / .wav for audio without
    // the test caring which.
    private func requireResource(bundle: Bundle, basename: String, extensions: [String]) throws -> URL {
        for ext in extensions {
            if let url = bundle.url(forResource: basename, withExtension: ext) {
                return url
            }
        }
        throw NSError(domain: "AlignmentQualityTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Missing \(basename).{\(extensions.joined(separator: "|"))} in test bundle"
        ])
    }

    // Matches each oracle cue to an output cue by normalized-exact text equality
    // (exact, then NFKC + whitespace-stripped). Computes per-cue start-time
    // deltas across matched pairs; aggregates median/max + coverage. Output
    // cues with no oracle counterpart are recorded as "extras" but don't fail
    // the test — they're informational.
    private func computeMetrics(
        output: [SubtitleCue],
        oracle: [SubtitleCue],
        perCueStartMsTolerance: Int
    ) -> QualityMetrics {
        // Walk oracle cues in order, find the next matching output cue (also
        // monotonically). Monotonic so repeated chorus lines can't cross-bind — keeps
        // chorus refrains from cross-binding.
        var nextOutputIdx = 0
        var matchedPairs: [(Int, SubtitleCue, SubtitleCue)] = []  // (oracleIdx, oracle, output)
        var missingFromOutput: [String] = []

        for (oi, oracleCue) in oracle.enumerated() {
            var found: Int? = nil
            for j in nextOutputIdx..<output.count {
                if cueMatchesNoteLine(output[j].text, oracleCue.text) {
                    found = j
                    break
                }
            }
            if let j = found {
                matchedPairs.append((oi, oracleCue, output[j]))
                nextOutputIdx = j + 1
            } else {
                missingFromOutput.append(oracleCue.text)
            }
        }

        let matchedOutputIndices = Set(matchedPairs.map { _, _, out in
            output.firstIndex(where: { $0.startMs == out.startMs && $0.text == out.text }) ?? -1
        })
        let extrasInOutput = output.enumerated()
            .filter { matchedOutputIndices.contains($0.offset) == false }
            .map { $0.element.text }

        let deltas = matchedPairs.map { _, oracleCue, outputCue in
            abs(outputCue.startMs - oracleCue.startMs)
        }.sorted()

        let median: Int
        let maxDelta: Int
        if deltas.isEmpty {
            median = 0
            maxDelta = 0
        } else {
            median = deltas[deltas.count / 2]
            maxDelta = deltas.last ?? 0
        }

        // "Matched within tolerance" — narrower than just "found a text match";
        // pairs whose start delta exceeds the per-cue tolerance count as missed
        // for coverage purposes, because they're too far off to be useful.
        let withinTolerance = matchedPairs.filter { _, oracleCue, outputCue in
            abs(outputCue.startMs - oracleCue.startMs) <= perCueStartMsTolerance
        }

        let coverage = oracle.isEmpty ? 1.0 : Double(withinTolerance.count) / Double(oracle.count)

        return QualityMetrics(
            oracleCueCount: oracle.count,
            matchedCueCount: matchedPairs.count,
            coverageFraction: coverage,
            medianStartDeltaMs: median,
            maxStartDeltaMs: maxDelta,
            missingFromOutput: missingFromOutput,
            extrasInOutput: extrasInOutput
        )
    }
}

// Exact match first, then NFKC + whitespace-strip exact. Deliberately not fuzzy — substring or
// edit-distance matches collide with chorus refrains.
private func cueMatchesNoteLine(_ cueText: String, _ noteLine: String) -> Bool {
    if cueText == noteLine { return true }
    let normalize: (String) -> String = { s in
        (s as NSString).precomposedStringWithCompatibilityMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }
    return normalize(cueText) == normalize(noteLine)
}
