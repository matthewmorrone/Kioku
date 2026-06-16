// SongCapabilityHarness.swift
//
// Manual, env-driven harness to run the app's two audio pipelines on a real song
// and write the actual outputs to disk for inspection:
//   • Transcription  — on-device SwiftWhisper free decode (audio -> text)
//   • Forced alignment — ForcedAligner (audio + known lyrics -> SRT)
//
// It self-skips unless the env vars below are set, so it never runs in a normal
// `swift test`. Drive it explicitly, e.g.:
//
//   KIOKU_AUDIO=/path/song.wav \
//   KIOKU_NOTE=/path/song.txt \
//   KIOKU_MODEL=/path/ggml-base.bin \
//   KIOKU_OUT_TXT=/path/out/transcription.txt \
//   KIOKU_OUT_SRT=/path/out/alignment.srt \
//   swift test --package-path SwiftWhisperAlign --filter SongCapabilityHarness
//
import XCTest
import Foundation
@testable import SwiftWhisperAlign
import SwiftWhisper

final class SongCapabilityHarness: XCTestCase {

    private struct Env {
        let audioURL: URL
        let modelURL: URL
        let noteURL: URL?
        let promptURL: URL?
        let outTxtURL: URL?
        let outSrtURL: URL?
    }

    private func env() throws -> Env {
        let e = ProcessInfo.processInfo.environment
        guard let audio = e["KIOKU_AUDIO"], let model = e["KIOKU_MODEL"] else {
            throw XCTSkip("Set KIOKU_AUDIO and KIOKU_MODEL to run the song capability harness.")
        }
        return Env(
            audioURL: URL(fileURLWithPath: audio),
            modelURL: URL(fileURLWithPath: model),
            noteURL: e["KIOKU_NOTE"].map { URL(fileURLWithPath: $0) },
            promptURL: e["KIOKU_PROMPT"].map { URL(fileURLWithPath: $0) },
            outTxtURL: e["KIOKU_OUT_TXT"].map { URL(fileURLWithPath: $0) },
            outSrtURL: e["KIOKU_OUT_SRT"].map { URL(fileURLWithPath: $0) }
        )
    }

    // TRANSCRIPTION: audio -> text, on-device Whisper (Japanese), no lyrics given.
    func testTranscribeSong() async throws {
        let env = try env()

        let frames = try await WhisperAudioFrameDecoder.decode(from: env.audioURL)
        XCTAssertFalse(frames.isEmpty, "Decoder produced no audio frames")

        var params = WhisperParams()
        params.language = .japanese

        // Bias toward the known vocabulary (the stemmed result) via whisper's
        // initial_prompt — this is the "stemming makes transcription easier" path.
        // strdup'd C string must outlive the transcribe call; freed after.
        var promptCStr: UnsafeMutablePointer<CChar>? = nil
        if let promptURL = env.promptURL,
           let prompt = try? String(contentsOf: promptURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
           prompt.isEmpty == false {
            promptCStr = strdup(prompt)
            params.whisperParams.initial_prompt = UnsafePointer(promptCStr)
            print("[harness] biasing transcription with prompt (\(prompt.count) chars)")
        }
        defer { if let p = promptCStr { free(p) } }

        let whisper = Whisper(fromFileURL: env.modelURL, withParams: params)

        let segments = try await whisper.transcribe(audioFrames: frames)
        let text = segments.map(\.text).joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        print(">>>TRANSCRIPT_BEGIN")
        print(trimmed)
        print(">>>TRANSCRIPT_END")

        XCTAssertFalse(trimmed.isEmpty, "Transcription produced empty text")
        if let out = env.outTxtURL {
            try trimmed.appending("\n").write(to: out, atomically: true, encoding: .utf8)
            print("[harness] wrote transcript -> \(out.path)")
        }
    }

    // FORCED ALIGNMENT: audio + known lyrics -> SRT, on-device DTW.
    func testAlignSong() async throws {
        let env = try env()
        let noteURL = try XCTUnwrap(env.noteURL, "Set KIOKU_NOTE (lyrics) to run alignment")

        let noteText = try String(contentsOf: noteURL, encoding: .utf8)
        let lines = noteText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        XCTAssertFalse(lines.isEmpty, "Note had no lyric lines")

        let aligner = ForcedAligner(modelURL: env.modelURL)
        let srt = try await aligner.alignToSRT(
            input: AlignmentInput(audioURL: env.audioURL, lines: lines, language: "ja"),
            cancellationCheck: { false },
            onProgress: { _ in }
        )

        print(">>>ALIGNED_SRT_BEGIN")
        print(srt)
        print(">>>ALIGNED_SRT_END")

        XCTAssertFalse(srt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Alignment produced empty SRT")
        if let out = env.outSrtURL {
            try srt.write(to: out, atomically: true, encoding: .utf8)
            print("[harness] wrote SRT -> \(out.path)")
        }
    }

    // MEASUREMENT: align audio+note with each model in KIOKU_MODELS (comma-separated
    // paths) and report per-line start-time deviation against a trusted oracle SRT
    // (KIOKU_ORACLE). Prints a table: matched lines, median/max Δ, and the share of
    // lines within ±200/±500/±1000 ms. Flags collapse when the last produced cue runs
    // past the audio end (the uniform-fill failure).
    func testMeasureAlignmentDeviation() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let audio = e["KIOKU_AUDIO"], let note = e["KIOKU_NOTE"],
              let oracle = e["KIOKU_ORACLE"], let models = e["KIOKU_MODELS"] else {
            throw XCTSkip("Set KIOKU_AUDIO, KIOKU_NOTE, KIOKU_ORACLE, KIOKU_MODELS to measure.")
        }
        let audioURL = URL(fileURLWithPath: audio)
        let lines = try String(contentsOfFile: note, encoding: .utf8)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        let oracleCues = Self.parseSRT(try String(contentsOfFile: oracle, encoding: .utf8))
            .filter { Self.isSpeech($0.text) }
        let frames = try await WhisperAudioFrameDecoder.decode(from: audioURL)
        let audioSec = Double(frames.count) / 16000.0

        print(">>>MEASURE_BEGIN")
        print(String(format: "audio %.1fs · oracle lines %d", audioSec, oracleCues.count))
        print("model        matched  median     max    <=200  <=500  <=1000  lastEnd")
        for modelPath in models.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ $0.isEmpty == false }) {
            let modelURL = URL(fileURLWithPath: modelPath)
            let name = modelURL.deletingPathExtension().lastPathComponent
            let srt = try await ForcedAligner(modelURL: modelURL).alignToSRT(
                input: AlignmentInput(audioURL: audioURL, lines: lines, language: "ja"),
                cancellationCheck: { false }, onProgress: { _ in })
            let produced = Self.parseSRT(srt).filter { Self.isSpeech($0.text) }
            let m = Self.metrics(produced: produced, oracle: oracleCues)
            let lastEnd = Double(produced.map(\.endMs).max() ?? 0) / 1000
            let flag = lastEnd > audioSec + 1.0 ? "  ⚠collapse" : ""
            print(String(format: "%-12@ %2d/%-2d   %6dms %6dms  %4.0f%%  %4.0f%%  %4.0f%%  %6.1fs%@",
                          name as NSString, m.matched, oracleCues.count, m.median, m.maxD,
                          m.pct200, m.pct500, m.pct1000, lastEnd, flag as NSString))
        }
        print(">>>MEASURE_END")
    }

    // MARK: - SRT parse + metrics helpers

    private struct Cue { let startMs: Int; let endMs: Int; let text: String }

    private static func parseSRT(_ s: String) -> [Cue] {
        var cues: [Cue] = []
        let blocks = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let ls = block.components(separatedBy: "\n").filter { $0.isEmpty == false }
            guard let timeIdx = ls.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = ls[timeIdx].components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            let text = ls[(timeIdx + 1)...].joined(separator: " ")
            cues.append(Cue(startMs: msFrom(parts[0]), endMs: msFrom(parts[1]), text: text))
        }
        return cues
    }

    private static func msFrom(_ t: String) -> Int {
        let parts = t.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ":").components(separatedBy: ":")
        guard parts.count == 4, let h = Int(parts[0]), let m = Int(parts[1]),
              let sec = Int(parts[2]), let mm = Int(parts[3]) else { return 0 }
        return ((h * 60 + m) * 60 + sec) * 1000 + mm
    }

    private static func isSpeech(_ t: String) -> Bool {
        let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return x.isEmpty == false && x.allSatisfy { "♪ 　\t".contains($0) } == false
    }

    private static func metrics(produced: [Cue], oracle: [Cue])
        -> (matched: Int, median: Int, maxD: Int, pct200: Double, pct500: Double, pct1000: Double) {
        func norm(_ s: String) -> String { s.components(separatedBy: .whitespacesAndNewlines).joined() }
        var cursor = 0
        var deltas: [Int] = []
        for o in oracle {
            for j in cursor..<produced.count where norm(produced[j].text) == norm(o.text) {
                deltas.append(abs(produced[j].startMs - o.startMs))
                cursor = j + 1
                break
            }
        }
        let sorted = deltas.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        func pct(_ th: Int) -> Double {
            oracle.isEmpty ? 0 : Double(deltas.filter { $0 <= th }.count) / Double(oracle.count) * 100
        }
        return (deltas.count, median, sorted.last ?? 0, pct(200), pct(500), pct(1000))
    }

    // MEASUREMENT: transcribe audio with each model in KIOKU_MODELS and report
    // character error rate (CER) against the known lyrics (KIOKU_NOTE) — the
    // "does a larger model help transcription" question, quantified. Lower is
    // better; CER counts insert/delete/substitute over the reference length.
    // Set KIOKU_PROMPT to also bias with the stemmed vocab.
    func testMeasureTranscriptionCER() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let audio = e["KIOKU_AUDIO"], let note = e["KIOKU_NOTE"], let models = e["KIOKU_MODELS"] else {
            throw XCTSkip("Set KIOKU_AUDIO, KIOKU_NOTE, KIOKU_MODELS to measure CER.")
        }
        let audioURL = URL(fileURLWithPath: audio)
        let ref = Self.normalizeForCER(try String(contentsOfFile: note, encoding: .utf8))
        let frames = try await WhisperAudioFrameDecoder.decode(from: audioURL)

        var promptCStr: UnsafeMutablePointer<CChar>? = nil
        if let p = e["KIOKU_PROMPT"],
           let s = try? String(contentsOfFile: p, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           s.isEmpty == false {
            promptCStr = strdup(s)
        }
        defer { if let p = promptCStr { free(p) } }

        print(">>>CER_BEGIN")
        print(String(format: "reference chars: %d   prompt-biased: %@", ref.count, promptCStr == nil ? "no" : "yes"))
        print("model         CER    hypChars")
        for modelPath in models.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ $0.isEmpty == false }) {
            let modelURL = URL(fileURLWithPath: modelPath)
            var params = WhisperParams()
            params.language = .japanese
            if let p = promptCStr { params.whisperParams.initial_prompt = UnsafePointer(p) }
            let whisper = Whisper(fromFileURL: modelURL, withParams: params)
            let segs = try await whisper.transcribe(audioFrames: frames)
            let hyp = Self.normalizeForCER(segs.map(\.text).joined())
            let cer = Self.cer(ref: ref, hyp: hyp)
            print(String(format: "%-12@ %5.1f%%  %6d", modelURL.deletingPathExtension().lastPathComponent as NSString, cer * 100, hyp.count))
        }
        print(">>>CER_END")
    }

    private static func normalizeForCER(_ s: String) -> [Character] {
        let drop = Set("　 \n\t「」『』、。，．・…！？!?()（）〜~[]【】\"'`♪")
        return Array(s).filter { drop.contains($0) == false }
    }

    private static func cer(ref: [Character], hyp: [Character]) -> Double {
        if ref.isEmpty { return hyp.isEmpty ? 0 : 1 }
        var prev = Array(0...hyp.count)
        var cur = [Int](repeating: 0, count: hyp.count + 1)
        for i in 1...ref.count {
            cur[0] = i
            for j in 1...hyp.count {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return Double(prev[hyp.count]) / Double(ref.count)
    }
}
