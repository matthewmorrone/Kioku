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
        // Audio identity (VocalStemCache.identityKey) enabling the resumable per-piece checkpoint.
        // nil disables checkpointing (diagnostic callers) and transcribes fresh.
        cacheIdentity: String? = nil,
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

        // Expected piece boundaries, computed up front so progress, resume-matching, and the
        // "fully cached → skip the model load" shortcut all share ONE source of truth.
        var pieces: [(t0: Double, t1: Double)] = []
        for reg in regs {
            var t = max(0, reg.start)
            let regEnd = min(reg.end, totalSec)
            while t < regEnd - 0.5 {
                let t1 = min(t + pieceSec, regEnd)
                pieces.append((t, t1))
                if t1 >= regEnd { break }
                t += step
            }
        }
        let totalChunks = max(1, pieces.count)

        // Resume: pull any pieces a prior (killed) run already transcribed, keyed by rounded start ms.
        // A cache hit replays its progress instantly; a full hit returns before the ~60 s model load.
        var cached: [Int: TranscriptCache.Piece] = [:]
        if let id = cacheIdentity {
            for p in TranscriptCache.load(identity: id, regions: regs, pieceSec: pieceSec) {
                cached[Int((p.start * 1000).rounded())] = p
            }
            if cached.isEmpty == false {
                progress?("resuming: \(cached.count)/\(totalChunks) pieces cached")
            }
        }
        let key: (Double) -> Int = { Int(($0 * 1000).rounded()) }
        let allCached = cacheIdentity != nil && pieces.allSatisfy { cached[key($0.t0)] != nil }

        // Accumulated transcript, seeded from cache and persisted after each newly-heard piece so a
        // kill at piece N resumes at piece N. Keep ordering by build time (regions are time-ordered).
        var collected: [TranscriptCache.Piece] = []
        var out: [(start: Double, end: Double, text: String)] = []
        func keep(_ p: TranscriptCache.Piece) {
            collected.append(p)
            if p.text.isEmpty == false && p.text.hasPrefix("[") == false { out.append((p.start, p.end, p.text)) }
        }

        // Lazily load the model only if at least one piece must actually be transcribed.
        var model: Qwen3ASRModel?
        func ensureModel() async throws -> Qwen3ASRModel {
            if let m = model { return m }
            progress?("loading ASR…")
            let m = try await Qwen3ASRModel.fromPretrained()   // MLX checkpoint, already cached
            model = m
            return m
        }
        if allCached { progress?("transcript fully cached — skipping ASR load") }

        var doneChunks = 0
        for (t0, t1) in pieces {
            if let hit = cached[key(t0)] {
                keep(hit)   // resumed piece — no model work, no re-persist needed
            } else {
                let s = Int(t0 * sr), e = min(stem.count, Int(t1 * sr))
                if e > s {
                    let piece = Array(stem[s..<e])
                    let text = (try await ensureModel())
                        .transcribe(audio: piece, sampleRate: sampleRate, language: language)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    MLX.GPU.clearCache()
                    progress?("\(Int(t0))–\(Int(t1))s → \(text.prefix(16))")
                    keep(TranscriptCache.Piece(start: t0, end: t1, text: text))
                    // Checkpoint the instant the piece lands, so this work survives a kill.
                    if let id = cacheIdentity {
                        TranscriptCache.store(collected, identity: id, regions: regs, pieceSec: pieceSec)
                    }
                }
            }
            doneChunks += 1
            onFraction?(min(1.0, Double(doneChunks) / Double(totalChunks)))
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
