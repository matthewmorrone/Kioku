// StemTranscriber.swift
//
// Transcribes the ISOLATED VOCAL STEM in fixed pieces over the supplied vocal regions, using the
// CoreML ASR model DIRECTLY (no Silero VAD in the path). This matters: the VAD-gated StreamingASR
// is front-loaded — Silero drops sustained sung vowels (the same reason alignment uses energy-VAD),
// so the back half never reaches the ASR. Forcing fixed pieces over the energy-VAD regions guarantees
// whole-song coverage, so anchor extraction can find matches in the back where the catastrophes live.
// Each piece's heard text is tagged with that piece's [start,end] time (for anchor interpolation).

import Foundation
import Qwen3ASR
import MLX

public enum StemTranscriber {
    // Transcribes `stem` in `pieceSec` chunks across each vocal region (defaults to the whole stem),
    // with a slight overlap so a line split across one boundary still appears whole in a neighbour.
    // Piece count is kept modest on purpose: each piece is an MLX forward pass holding the ASR model
    // resident, and too many in a row gets the app jetsam-killed (50% overlap / ~31 pieces did).
    // Anchor PRECISION comes from the downstream refine pass, not from tiny pieces. One phrase per
    // non-empty piece.
    public static func segments(
        stem: [Float],
        sampleRate: Int = 44_100,
        regions: [(start: Double, end: Double)]? = nil,
        pieceSec: Double = 24,
        language: String = "Japanese",
        progress: (@Sendable (String) -> Void)? = nil,
        onFraction: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [(start: Double, end: Double, text: String)] {
        guard stem.isEmpty == false else { return [] }
        let sr = Double(sampleRate)
        let totalSec = Double(stem.count) / sr
        let regs = (regions?.isEmpty == false ? regions! : [(start: 0, end: totalSec)])
        // No overlap: denser/overlapping pieces measured as a wash (the residual error sits in a
        // stretch that transcribes as garbage at any resolution) and add jetsam risk. ~9 pieces.
        let step = pieceSec
        // Estimated chunk count for a 0–1 progress signal (onFraction). Approximate — the last chunk
        // in each region is clamped to the region end — but good enough for a progress bar.
        let totalChunks = max(1, regs.reduce(0) { acc, reg in
            let d = min(reg.end, totalSec) - max(0, reg.start)
            return acc + (d > 0.5 ? Int(ceil(d / step)) : 0)
        })
        var doneChunks = 0

        progress?("loading ASR…")
        // Pin to a non-purgeable Application Support path so a Caches eviction can't strand a
        // mid-transfer download (see ModelStorage for the full rationale).
        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: ModelStorage.asrModelId,
            cacheDir: try ModelStorage.directory(for: ModelStorage.asrModelId)
        )

        var out: [(start: Double, end: Double, text: String)] = []
        for reg in regs {
            var t = max(0, reg.start)
            let regEnd = min(reg.end, totalSec)
            while t < regEnd - 0.5 {
                let t1 = min(t + pieceSec, regEnd)
                let s = Int(t * sr), e = min(stem.count, Int(t1 * sr))
                if e > s {
                    let piece = Array(stem[s..<e])
                    let text = model.transcribe(audio: piece, sampleRate: sampleRate, language: language)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    MLX.GPU.clearCache()
                    progress?("\(Int(t))–\(Int(t1))s → \(text.prefix(16))")
                    if text.isEmpty == false && text.hasPrefix("[") == false {   // skip "[error …]" sentinels
                        out.append((start: t, end: t1, text: text))
                    }
                }
                doneChunks += 1
                onFraction?(min(1.0, Double(doneChunks) / Double(totalChunks)))
                if t1 >= regEnd { break }
                t += step
            }
        }
        return out
    }

    // Convenience: transcribes the cached vocal stem for `audioURL` over the whole stem (diagnostic).
    public static func segments(
        stemFor audioURL: URL,
        sampleRate: Int = 44_100,
        language: String = "Japanese",
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [(start: Double, end: Double, text: String)] {
        guard let stem = VocalStemCache.load(for: audioURL), stem.isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.StemTranscriber", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No cached vocal stem — align the song first."])
        }
        return try await segments(stem: stem, sampleRate: sampleRate, language: language, progress: progress)
    }
}
