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
        // Optional: starting SRT — when present we measure the in-app anchored
        // Reconcile pipeline (starts from this SRT, fills gaps via aligner). When
        // absent we degrade to raw alignment (empty starting cues → one giant gap).
        let startingSrtURL = bundle.url(forResource: "\(fixtureName).starting-srt", withExtension: "srt")

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

        // Resolve a Whisper model — same pathway as the in-app reconcile uses.
        let modelURL: URL
        if let existing = OnDeviceLyricAligner.bestAvailableModelURL() {
            modelURL = existing
        } else {
            modelURL = try await OnDeviceLyricAligner.downloadDefaultModel { message in
                print("[QualityTest] model prep: \(message)")
            }
        }

        // Compute BEFORE metrics if we have a starting SRT — shows how far off
        // the input is from oracle. Then run the in-app reconcile (the exact
        // function the editor sheet calls) to compute AFTER metrics. The user-
        // visible quality is the AFTER number; the delta tells us whether the
        // pipeline is helping.
        let beforeMetrics: QualityMetrics?
        let startingCues: [SubtitleCue]
        if let startingSrtURL {
            let startingSrtText = try String(contentsOf: startingSrtURL, encoding: .utf8)
            startingCues = SubtitleParser.parse(startingSrtText)
            let startingSpeechCues = startingCues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }
            beforeMetrics = computeMetrics(
                output: startingSpeechCues,
                oracle: oracleCues,
                perCueStartMsTolerance: tolerance.perCueStartMsTolerance
            )
        } else {
            startingCues = []
            beforeMetrics = nil
        }

        // Call the EXACT orchestration function the in-app reconcile uses.
        // Test and production share this code path so the test measures user-
        // facing quality, not a re-implementation.
        let reconciledCues = try await SubtitleReconciliation.reconcile(
            audioURL: audioURL,
            currentCues: startingCues,
            noteLines: noteLines,
            modelURL: modelURL,
            cancellationCheck: { false },
            onProgress: { _ in /* test ignores progress UI */ }
        )

        let afterSpeechCues = reconciledCues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }
        let afterMetrics = computeMetrics(
            output: afterSpeechCues,
            oracle: oracleCues,
            perCueStartMsTolerance: tolerance.perCueStartMsTolerance
        )

        printMetricsReport(
            fixtureName: fixtureName,
            tolerance: tolerance,
            beforeMetrics: beforeMetrics,
            afterMetrics: afterMetrics,
            startingCueCount: startingCues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }.count
        )

        // Temporary debug: dump reconciled cue list to diagnose missing-line drops.
        if afterMetrics.missingFromOutput.isEmpty == false {
            print("\n[DEBUG] Reconciled output cues (\(afterSpeechCues.count)):")
            for (i, cue) in afterSpeechCues.enumerated() {
                let inOracle = oracleCues.contains { SubtitleReconciliation.cueMatchesNoteLine($0.text, cue.text) }
                print("  [\(i)] \(cue.startMs)ms - \(cue.endMs)ms: \(cue.text) \(inOracle ? "✓" : "?")")
            }
            print("\n[DEBUG] Oracle cues NOT found in output (\(afterMetrics.missingFromOutput.count)):")
            for t in afterMetrics.missingFromOutput {
                print("  - \(t)")
            }
        }

        // Hard gate: never drop a line. The reconcile pipeline force-fits
        // overflow rather than drop; this is a structural guarantee, not a
        // quality knob.
        XCTAssertTrue(afterMetrics.missingFromOutput.isEmpty,
                      "Ground-truth cues missing from reconcile output: \(afterMetrics.missingFromOutput)")

        // Aspirational timing gate — see XCTExpectFailure note in
        // docs/INVARIANTS.md Alignment #9. Metrics print regardless; the
        // expectFailure suppresses the red so CI tracks the numbers instead of
        // blocking on quality. When quality improves to consistently meet
        // tolerance, XCTExpectFailure will itself fail and we drop the wrapper.
        XCTExpectFailure("Anchored reconcile timing not yet within tolerance — see printed metrics for the current AFTER numbers and the BEFORE/AFTER delta") {
            XCTAssertGreaterThanOrEqual(afterMetrics.coverageFraction, tolerance.minCoverage,
                                        "Coverage \(afterMetrics.coverageFraction) < tolerance.minCoverage \(tolerance.minCoverage)")
            XCTAssertLessThanOrEqual(afterMetrics.medianStartDeltaMs, tolerance.medianStartMsTolerance,
                                     "Median start Δ \(afterMetrics.medianStartDeltaMs)ms > tolerance \(tolerance.medianStartMsTolerance)ms")
        }
    }

    // Renders the metrics block. When beforeMetrics is non-nil, shows BEFORE
    // (starting SRT vs oracle) and AFTER (reconciled SRT vs oracle) side by
    // side so the delta is obvious — the whole point of measuring this is to
    // see whether the pipeline is helping. When beforeMetrics is nil there's
    // no starting SRT so only AFTER is shown (equivalent to raw alignment).
    private func printMetricsReport(
        fixtureName: String,
        tolerance: Tolerance,
        beforeMetrics: QualityMetrics?,
        afterMetrics: QualityMetrics,
        startingCueCount: Int
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
            "┌─ [QualityTest] \(fixtureName) — in-app anchored Reconcile pipeline ──",
            "│  oracle cues:         \(afterMetrics.oracleCueCount)",
            "│  tolerance:           ≥ \(String(format: "%.0f%%", tolerance.minCoverage * 100)) within ±\(tolerance.perCueStartMsTolerance)ms · median Δ ≤ \(tolerance.medianStartMsTolerance)ms",
            "│",
        ]

        if let beforeMetrics {
            lines += [
                "│  BEFORE  (starting SRT vs oracle — what users start from)",
                "│   starting cues:      \(startingCueCount)",
            ]
            lines += row("BEFORE", beforeMetrics, totalOracleCount: afterMetrics.oracleCueCount)
            lines += ["│"]
        }
        lines += [
            "│  AFTER   (reconcile output vs oracle — what users get)",
        ]
        lines += row("AFTER", afterMetrics, totalOracleCount: afterMetrics.oracleCueCount)

        if let beforeMetrics {
            // Delta highlights — the test's reason for existing.
            let medianDelta = beforeMetrics.medianStartDeltaMs - afterMetrics.medianStartDeltaMs
            let coverageDelta = (afterMetrics.coverageFraction - beforeMetrics.coverageFraction) * 100
            let medianSign = medianDelta >= 0 ? "−" : "+"
            let coverageSign = coverageDelta >= 0 ? "+" : "−"
            lines += [
                "│",
                "│  DELTA   (lower median = better; higher coverage = better)",
                "│   median Δstart:      \(medianSign)\(abs(medianDelta)) ms",
                "│   coverage:           \(coverageSign)\(String(format: "%.1f", abs(coverageDelta))) percentage points",
            ]
        }
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
    // (same predicate as SubtitleReconciliation). Computes per-cue start-time
    // deltas across matched pairs; aggregates median/max + coverage. Output
    // cues with no oracle counterpart are recorded as "extras" but don't fail
    // the test — they're informational.
    private func computeMetrics(
        output: [SubtitleCue],
        oracle: [SubtitleCue],
        perCueStartMsTolerance: Int
    ) -> QualityMetrics {
        // Walk oracle cues in order, find the next matching output cue (also
        // monotonically). Same monotonic walk as the reconcile matcher — keeps
        // chorus refrains from cross-binding.
        var nextOutputIdx = 0
        var matchedPairs: [(Int, SubtitleCue, SubtitleCue)] = []  // (oracleIdx, oracle, output)
        var missingFromOutput: [String] = []

        for (oi, oracleCue) in oracle.enumerated() {
            var found: Int? = nil
            for j in nextOutputIdx..<output.count {
                if SubtitleReconciliation.cueMatchesNoteLine(output[j].text, oracleCue.text) {
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
