import XCTest
@testable import Kioku

// Pins docs/INVARIANTS.md Alignment #9 — alignment quality against ground truth.
//
// Slow tests: each fixture runs the full on-device aligner on a real audio file, then
// compares the output cues to a stable-ts large-v3 oracle.
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

    // Every fixture in the bundle, one after another, then a summary table. This is the
    // benchmark to grade alignment changes on: one song is a single data point, and the
    // stable-ts oracles are themselves only good to a few hundred ms, so what matters is the
    // aggregate and whether a change moves many songs the same way. Slow: a song whose vocal
    // stem isn't cached yet pays the isolation (~1 min) once.
    func testQuality_AllFixtures() async throws {
        let bundle = Bundle(for: type(of: self))
        let names = (bundle.urls(forResourcesWithExtension: "txt", subdirectory: nil) ?? [])
            .map { $0.lastPathComponent }
            .filter { $0.hasSuffix(".note.txt") }
            .map { String($0.dropLast(".note.txt".count)) }
            .sorted()
        guard names.isEmpty == false else { throw XCTSkip("No alignment fixtures in the test bundle.") }

        var rows: [(name: String, metrics: QualityMetrics)] = []
        for name in names {
            rows.append((name, try await runQualityCheck(fixtureName: name)))
        }
        var lines = ["", "┌─ [QualityTest] all fixtures ──", "│  song                              lines  within±500ms   median    max   missing   words  within±500ms   median"]
        var withinTotal = 0, cueTotal = 0, medians: [Int] = [], wordsWithinTotal = 0, wordTotal = 0
        for r in rows {
            let within = Int((Double(r.metrics.matchedCueCount) * r.metrics.coverageFraction).rounded())
            withinTotal += within; cueTotal += r.metrics.oracleCueCount; medians.append(r.metrics.medianStartDeltaMs)
            wordsWithinTotal += r.metrics.wordsWithinCount; wordTotal += r.metrics.wordCount
            let wordPct = r.metrics.wordCount == 0 ? 0 : Double(r.metrics.wordsWithinCount) / Double(r.metrics.wordCount) * 100
            lines.append(String(format: "│  %-32@ %5d  %3d (%5.1f%%)  %6dms %6dms  %d   %5d  %4d (%5.1f%%)  %6dms",
                                r.name as NSString, r.metrics.oracleCueCount, within, r.metrics.coverageFraction * 100,
                                r.metrics.medianStartDeltaMs, r.metrics.maxStartDeltaMs, r.metrics.missingFromOutput.count,
                                r.metrics.wordCount, r.metrics.wordsWithinCount, wordPct, r.metrics.wordMedianDeltaMs))
        }
        let sortedMedians = medians.sorted()
        lines.append(String(format: "│  TOTAL %d songs: %d / %d lines within ±500ms (%.1f%%), median of medians %dms",
                            rows.count, withinTotal, cueTotal, cueTotal == 0 ? 0 : Double(withinTotal) / Double(cueTotal) * 100,
                            sortedMedians.isEmpty ? 0 : sortedMedians[sortedMedians.count / 2]))
        lines.append(String(format: "│  WORDS %d / %d within ±500ms (%.1f%%)",
                            wordsWithinTotal, wordTotal, wordTotal == 0 ? 0 : Double(wordsWithinTotal) / Double(wordTotal) * 100))
        lines.append("└────────────────────────────────────────────────────────────────────")
        print(lines.joined(separator: "\n"))
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
        let wordCount: Int                   // reference words (kakasi chunks) graded
        let wordsWithinCount: Int            // of those, within perCueStartMsTolerance
        let wordMedianDeltaMs: Int
        let wordMaxDeltaMs: Int
    }

    // One confirmed sub-line reference point from `<fixture>.words.json`: the UTF-16 range of a
    // kakasi chunk in its lyric line and the consensus start of its first character.
    private struct RefWord: Decodable {
        let off: Int
        let len: Int
        let start: Double
    }

    // Loads a fixture, runs the on-device aligner, and asserts the result is
    // within tolerance of the oracle. Throws (via XCTFail) on any threshold
    // violation; prints metrics on success so passing runs still tell you how
    // close you actually were.
    @discardableResult
    private func runQualityCheck(fixtureName: String) async throws -> QualityMetrics {
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
        // Optional word-level reference, one array per lyric line in note order.
        let refWords: [[RefWord]]? = try bundle.url(forResource: "\(fixtureName).words", withExtension: "json")
            .map { try JSONDecoder().decode([[RefWord]].self, from: Data(contentsOf: $0)) }

        let oracleCues = SubtitleParser.parse(oracleText)
            .filter { SubtitleParser.isNonSpeechCue($0.text) == false }
        let noteLines = noteText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && SubtitleParser.isNonSpeechCue($0) == false }

        // Call the EXACT function the app's Re-align actions use. Test and production share
        // this code path so the test measures user-facing quality, not a re-implementation.
        // Romanization comes from the real dictionary-backed segmenter, as in the app.
        let resources = try TestReadResources.shared()
        let romanizer = LyricRomanizer(
            segmenter: resources.segmenter,
            surfaceReadingData: SurfaceReadingDataMap(try resources.dictionaryStore.fetchSurfaceReadingData()),
            kanjiReadingFallback: KanjiReadingFallbackMap(try resources.dictionaryStore.fetchKanjiReadingFallbackMap())
        )
        let alignedCues = try await WholeSongAlignment.cues(
            audioURL: audioURL,
            lyrics: noteLines.joined(separator: "\n"),
            romanize: romanizer.spans(for:)
        )

        let afterSpeechCues = alignedCues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }
        let afterMetrics = computeMetrics(
            output: afterSpeechCues,
            oracle: oracleCues,
            noteLines: noteLines,
            refWords: refWords,
            perCueStartMsTolerance: tolerance.perCueStartMsTolerance
        )

        printMetricsReport(
            fixtureName: fixtureName,
            tolerance: tolerance,
            afterMetrics: afterMetrics
        )

        // Diagnostic: every matched cue in song order with its SIGNED start delta (negative =
        // output is early) and both cues' spans, so a grading run shows not just which line is
        // off but which way, and whether the miss tracks a pause before the line. Monotonic
        // walk mirrors computeMetrics.
        do {
            var nextOracle = 0, nextOut = 0
            print("\n[DEBUG] Per-cue (song order; Δ<0 = output early):")
            print("   Δstart      oracle span          out span             text")
            for line in noteLines {
                guard let oi = (nextOracle..<oracleCues.count).first(where: { cueMatchesNoteLine(oracleCues[$0].text, line) }) else { continue }
                nextOracle = oi + 1
                guard let j = (nextOut..<afterSpeechCues.count).first(where: { cueMatchesNoteLine(afterSpeechCues[$0].text, line) }) else { continue }
                nextOut = j + 1
                let o = oracleCues[oi], out = afterSpeechCues[j]
                print(String(format: "  %+6dms  %6d–%6dms  %6d–%6dms  %@",
                             out.startMs - o.startMs, o.startMs, o.endMs, out.startMs, out.endMs, line))
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
        let gate = XCTExpectedFailure.Options()
        gate.isStrict = false   // songs that already meet the gate must not error for lacking a failure
        XCTExpectFailure("Alignment timing not yet within tolerance — see printed metrics for the current AFTER numbers and the BEFORE/AFTER delta", options: gate) {
            XCTAssertGreaterThanOrEqual(afterMetrics.coverageFraction, tolerance.minCoverage,
                                        "Coverage \(afterMetrics.coverageFraction) < tolerance.minCoverage \(tolerance.minCoverage)")
            XCTAssertLessThanOrEqual(afterMetrics.medianStartDeltaMs, tolerance.medianStartMsTolerance,
                                     "Median start Δ \(afterMetrics.medianStartDeltaMs)ms > tolerance \(tolerance.medianStartMsTolerance)ms")
        }
        return afterMetrics
    }

    // Renders the metrics block: the aligned output graded against the oracle.
    private func printMetricsReport(
        fixtureName: String,
        tolerance: Tolerance,
        afterMetrics: QualityMetrics
    ) {
        let perCueStartMsTolerance = tolerance.perCueStartMsTolerance
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
                "│   words:              \(metrics.wordsWithinCount) / \(metrics.wordCount) within ±\(perCueStartMsTolerance)ms · median \(metrics.wordMedianDeltaMs) ms · max \(metrics.wordMaxDeltaMs) ms",
            ]
        }

        var lines: [String] = [
            "",
            "┌─ [QualityTest] \(fixtureName) — whole-song alignment ──",
            "│  graded lines:        \(afterMetrics.oracleCueCount)",
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

    // Walks the NOTE LINES (the thing the aligner places) and, for each, finds its oracle cue
    // and its output cue by normalized-exact text, both monotonically so repeated chorus lines
    // can't cross-bind. Oracle cues that match no note line are ignored: stable-ts sometimes
    // emits fragment cues ("…ダイアモ" / "ンド 夜明けに…") or repeats, and those are oracle
    // noise, not lines the aligner failed to place. A note line with no oracle cue can't be
    // graded and is left out of the deltas.
    private func computeMetrics(
        output: [SubtitleCue],
        oracle: [SubtitleCue],
        noteLines: [String],
        refWords: [[RefWord]]?,
        perCueStartMsTolerance: Int
    ) -> QualityMetrics {
        var nextOracle = 0
        var nextOutput = 0
        var deltas: [Int] = []
        var wordDeltas: [Int] = []
        var missingFromOutput: [String] = []
        var matchedOutputIndices = Set<Int>()

        for (li, line) in noteLines.enumerated() {
            guard let oi = (nextOracle..<oracle.count).first(where: { cueMatchesNoteLine(oracle[$0].text, line) }) else {
                continue   // ungradable: the oracle never produced this line
            }
            nextOracle = oi + 1
            // A consensus oracle lists a line its aligners disagreed on as a zero-time cue: the line
            // start is ungradable, but its confirmed words (if any) still are.
            let lineDisputed = oracle[oi].startMs == 0 && oracle[oi].endMs == 0
            guard let j = (nextOutput..<output.count).first(where: { cueMatchesNoteLine(output[$0].text, line) }) else {
                if lineDisputed == false { missingFromOutput.append(line) }
                continue
            }
            nextOutput = j + 1
            matchedOutputIndices.insert(j)
            if let refWords, li < refWords.count {
                for w in refWords[li] {
                    guard let cp = output[j].checkpoints.first(where: { w.off >= $0.charOffsetInCue && w.off < $0.charOffsetInCue + $0.charLength }) else { continue }
                    wordDeltas.append(abs(cp.timeMs - Int((w.start * 1000).rounded())))
                }
            }
            if lineDisputed { continue }
            deltas.append(abs(output[j].startMs - oracle[oi].startMs))
        }

        let extrasInOutput = output.enumerated()
            .filter { matchedOutputIndices.contains($0.offset) == false }
            .map { $0.element.text }
        let sorted = deltas.sorted()
        let sortedWords = wordDeltas.sorted()
        let graded = deltas.count + missingFromOutput.count
        return QualityMetrics(
            oracleCueCount: graded,
            matchedCueCount: deltas.count,
            coverageFraction: graded == 0 ? 1.0 : Double(deltas.filter { $0 <= perCueStartMsTolerance }.count) / Double(graded),
            medianStartDeltaMs: sorted.isEmpty ? 0 : sorted[sorted.count / 2],
            maxStartDeltaMs: sorted.last ?? 0,
            missingFromOutput: missingFromOutput,
            extrasInOutput: extrasInOutput,
            wordCount: wordDeltas.count,
            wordsWithinCount: wordDeltas.filter { $0 <= perCueStartMsTolerance }.count,
            wordMedianDeltaMs: sortedWords.isEmpty ? 0 : sortedWords[sortedWords.count / 2],
            wordMaxDeltaMs: sortedWords.last ?? 0
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
