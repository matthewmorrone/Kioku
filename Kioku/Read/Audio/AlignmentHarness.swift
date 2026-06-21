import Foundation
import SwiftWhisperAlign
#if canImport(UIKit)
import UIKit
#endif

// Headless on-device alignment harness for autonomous tuning. When the app is launched with the
// KIOKU_ALIGN_HARNESS environment variable set, it runs CTCForcedAligner (the exact whole-note
// Re-align aligner) on a song staged at <Documents>/harness/ (audio.mp3 + note.txt + oracle.srt),
// scores the result against the oracle, and writes a metrics report to <Documents>/harness/result.txt.
// This lets the aligner be triggered and measured on the real device with no UI interaction — build,
// launch with the env var, pull result.txt — so the windowing/feed/plateau logic can be iterated
// against ground truth where MLX + HTDemucs actually work. Gated to DEBUG and the env var, so it is
// inert in normal use.
enum AlignmentHarness {

    // Kicks off the harness in the background iff KIOKU_ALIGN_HARNESS is set; a no-op otherwise.
    // Called once at app launch.
    static func runIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["KIOKU_ALIGN_HARNESS"] != nil else { return }
        Task.detached(priority: .userInitiated) { await run() }
        #endif
    }

    #if DEBUG
    // Loads the staged song, runs the aligner, scores against the oracle, and writes the report.
    private static func run() async {
        #if canImport(UIKit)
        // A headless launch leaves the app foreground but idle; when the screen auto-locks the OS
        // suspends it mid-align and strands result.txt at "RUNNING" (the measurement flakiness that
        // cost many iterations). Keep the device awake AND claim background time so the run finishes
        // regardless of screen state. DEBUG/harness-only — never touches normal use.
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        let bgTask = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "kioku.align-harness")
        }
        defer {
            Task { @MainActor in
                UIApplication.shared.isIdleTimerDisabled = false
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            }
        }
        #endif
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("harness", isDirectory: true)
        let resultURL = dir.appendingPathComponent("result.txt")
        let emit: @Sendable (String) -> Void = { try? $0.write(to: resultURL, atomically: true, encoding: .utf8) }
        emit("RUNNING \(Date())\n")
        do {
            // Transcription-test mode (KIOKU_TRANSCRIBE): dump the streaming-ASR phrase segments of
            // the cached vocal stem, so we can see whether the heard text is close enough to the
            // lyrics to drive a content match instead of the char-rate guess.
            if ProcessInfo.processInfo.environment["KIOKU_TRANSCRIBE"] != nil {
                let audioURL = dir.appendingPathComponent("audio.mp3")
                let segs = try await StemTranscriber.segments(
                    stemFor: audioURL, sampleRate: 44_100,
                    progress: { emit("RUNNING transcribe: \($0)\n") }
                )
                var out = "DONE transcribe (\(segs.count) phrases)\n"
                for s in segs { out += String(format: "%6.1f–%6.1fs  %@\n", s.start, s.end, s.text as NSString) }
                emit(out)
                return
            }
            let lines = try String(contentsOf: dir.appendingPathComponent("note.txt"), encoding: .utf8)
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
            let oracle = SubtitleParser.parse(try String(contentsOf: dir.appendingPathComponent("oracle.srt"), encoding: .utf8))
                .filter { SubtitleParser.isNonSpeechCue($0.text) == false }
            let audioURL = dir.appendingPathComponent("audio.mp3")

            let result = try await CTCForcedAligner().align(
                input: AlignmentInput(audioURL: audioURL, lines: lines, language: "ja"),
                cancellationCheck: { false }
            )
            let produced = result.lines
                .map { (startMs: Int(($0.start * 1000).rounded()), text: $0.text) }
                .filter { SubtitleParser.isNonSpeechCue($0.text) == false }
            var out = report(produced: produced, oracle: oracle)
            // Per-word checkpoint coverage: how much of each line has per-word tokens (the karaoke
            // highlight data). cover < 100% = words with no checkpoint, which don't highlight.
            var fullCov = 0
            var totalTies = 0
            out += "--- per-word coverage (tokens / covered-UTF16-chars / tied-times) ---\n"
            for (i, line) in result.lines.enumerated() {
                let toks = i < result.lineTokens.count ? result.lineTokens[i] : []
                let covered = toks.reduce(0) { $0 + $1.charLengthUTF16 }
                let total = (line.text as NSString).length
                let pct = total > 0 ? covered * 100 / total : 100
                if pct >= 95 { fullCov += 1 }
                var ties = 0
                if toks.count > 1 { for t in 1..<toks.count where toks[t].start <= toks[t - 1].start { ties += 1 } }
                totalTies += ties
                out += String(format: "[%2d] tok=%2d cover=%3d%% ties=%d  %@\n", i, toks.count, pct, ties, line.text as NSString)
            }
            // Instrumental gaps >5s (where ♪ markers get inserted) — verifies a line no longer
            // absorbs an interlude into its duration.
            var bigGaps: [String] = []
            if result.lines.count > 1 {
                for i in 0..<(result.lines.count - 1) {
                    let gap = result.lines[i + 1].start - result.lines[i].end
                    if gap > 5.0 { bigGaps.append(String(format: "%.0f–%.0fs(%.0fs)", result.lines[i].end, result.lines[i + 1].start, gap)) }
                }
            }
            // Checkpoint-spacing evenness (the DATA side of "fits and starts"): within each line,
            // how much the largest gap between consecutive word checkpoints exceeds the average.
            // 1× = perfectly even; high = the highlight sits on a word then jumps. (The renderer's
            // interpolation smooths the rendered motion regardless; this measures the raw data.)
            var burstyLines = 0
            var worstBurst = 0.0
            for toks in result.lineTokens where toks.count >= 3 {
                var gaps: [Double] = []
                for t in 1..<toks.count { gaps.append(toks[t].start - toks[t - 1].start) }
                let mean = gaps.reduce(0, +) / Double(gaps.count)
                let burst = mean > 0 ? (gaps.max() ?? 0) / mean : 0
                if burst > 2.5 { burstyLines += 1 }
                worstBurst = max(worstBurst, burst)
            }
            out = "fullyCovered \(fullCov)/\(result.lines.count) · tiedTimes \(totalTies) · gaps>5s: \(bigGaps.isEmpty ? "none" : bigGaps.joined(separator: " ")) · bursty(>2.5×) \(burstyLines) worst \(String(format: "%.1f", worstBurst))×\n" + out
            emit(out)
        } catch {
            emit("ERROR: \(error)\n")
        }
    }

    // Builds the metrics report: coverage, median/max start-Δ vs oracle, % within thresholds, and a
    // per-line Δ dump (so drift can be traced to the exact line it starts at). Matches produced cues
    // to oracle cues by normalized text in order — the same monotonic text match the app uses.
    private static func report(produced: [(startMs: Int, text: String)], oracle: [SubtitleCue]) -> String {
        let norm: (String) -> String = { $0.components(separatedBy: .whitespacesAndNewlines).joined() }
        var deltas: [Int] = []
        var cursor = 0
        var perLine: [String] = []
        for o in oracle {
            var matchedIndex: Int? = nil
            for j in cursor..<produced.count where norm(produced[j].text) == norm(o.text) {
                matchedIndex = j; cursor = j + 1; break
            }
            if let j = matchedIndex {
                let d = produced[j].startMs - o.startMs
                deltas.append(abs(d))
                perLine.append(String(format: "Δ%+6dms  prod %7.2fs  oracle %7.2fs  %@",
                                      d, Double(produced[j].startMs) / 1000, Double(o.startMs) / 1000, o.text as NSString))
            } else {
                perLine.append(String(format: "MISSING                         oracle %7.2fs  %@",
                                      Double(o.startMs) / 1000, o.text as NSString))
            }
        }
        let sorted = deltas.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let maxD = sorted.last ?? 0
        let pct: (Int) -> Double = { t in oracle.isEmpty ? 0 : Double(deltas.filter { $0 <= t }.count) / Double(oracle.count) * 100 }
        let coverage = oracle.isEmpty ? 0 : Double(deltas.count) / Double(oracle.count) * 100
        var out = "DONE\n"
        out += String(format: "produced %d  oracle %d  matched %d  coverage %.0f%%  median %dms  max %dms  <=200 %.0f%%  <=500 %.0f%%  <=1000 %.0f%%\n",
                      produced.count, oracle.count, deltas.count, coverage, median, maxD, pct(200), pct(500), pct(1000))
        out += perLine.joined(separator: "\n") + "\n"
        return out
    }
    #endif
}
