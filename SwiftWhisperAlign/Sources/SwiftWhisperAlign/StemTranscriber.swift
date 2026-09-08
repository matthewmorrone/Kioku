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
import CoreML
import MLX

public enum StemTranscriber {
    // Transcribes `stem` in `pieceSec` chunks across each vocal region (defaults to the whole stem),
    // with a slight overlap so a line split across one boundary still appears whole in a neighbour.
    // Piece count used to be kept modest on purpose: each piece was an MLX forward pass holding the
    // ASR model resident, and too many in a row got the app jetsam-killed (50% overlap / ~31 pieces
    // did). Now that ASR runs on CoreML (see ensureModel below) instead of MLX, that specific memory
    // profile no longer applies — a 24s-piece run stayed well clear of jetsam (lowest observed
    // ~440 MB free over 10 pieces). The underlying tradeoff (more, smaller pieces = more total
    // ASR inference time, in exchange for denser, better-localized anchor candidates) is still
    // real; revisit pieceSec if jetsam resurfaces at this smaller size.
    public static func segments(
        stem: [Float],
        sampleRate: Int = 44_100,
        regions: [(start: Double, end: Double)]? = nil,
        pieceSec: Double = 12,
        language: String = "Japanese",
        // Audio identity (VocalStemCache.identityKey) enabling the resumable per-piece checkpoint.
        // nil disables checkpointing (diagnostic callers) and transcribes fresh.
        cacheIdentity: String? = nil,
        progress: (@Sendable (String) -> Void)? = nil,
        onFraction: (@Sendable (Double) -> Void)? = nil,
        cancellationCheck: (@Sendable () -> Bool)? = nil
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
        // CoreML (not the MLX build): on-device testing (iOS 27 beta, A19 Pro) hit a repeatable
        // SIGSEGV inside MLX's own CPU bfloat16 multiply kernel during Qwen3ASRModel's token
        // generation — a native crash `withError` can't catch (that only intercepts errors MLX
        // reports through its own C API, not raw memory faults). CoreMLASRModel is the same
        // model exported to CoreML, run via transcribeBackgroundSafe() which explicitly avoids
        // MLXArray for the whole forward pass (its own doc comment: built for exactly this class
        // of crash, in code paths where "GPU access is prohibited").
        var model: CoreMLASRModel?
        func ensureModel() async throws -> CoreMLASRModel {
            if let m = model { return m }
            progress?("loading ASR…")
            // Pin to a non-purgeable Application Support path so a Caches eviction can't strand a
            // mid-transfer download (see ModelStorage for the full rationale).
            let coreMLDir = try ModelStorage.directory(for: ModelStorage.asrCoreMLModelId)
            // fromPretrained's tokenizer step downloads from `tokenizerModelId` (the MLX repo) but
            // writes into the SAME `cacheDir` passed for encoder/decoder (the CoreML repo) — that
            // modelId/cacheDir mismatch confuses the Hub downloader's internal path derivation
            // (see ModelStorage.swift's "models/" comment) and the tokenizer files silently never
            // land, so `model.tokenizer` stays nil and transcribe() falls back to raw token IDs
            // ("11528 8453 15170") instead of decoded text. Pre-seeding the files directly at the
            // exact path fromPretrained checks sidesteps the mismatch (downloadWeights already
            // skips files that already exist).
            let vocabURL = coreMLDir.appendingPathComponent("vocab.json")
            if FileManager.default.fileExists(atPath: vocabURL.path) == false {
                // Pinned commit for aufklarer/Qwen3-ASR-0.6B-MLX-4bit (2026-09-04).
                let tokenizerRevision = "bc441bd1e4295c1f42d9879f056049a925b6e013"
                func tokenizerFileURL(_ filename: String) -> URL {
                    URL(string: "https://huggingface.co/aufklarer/Qwen3-ASR-0.6B-MLX-4bit/resolve/\(tokenizerRevision)/\(filename)")!
                }
                for filename in ["vocab.json", "merges.txt", "tokenizer_config.json"] {
                    try await HTDemucsFTDownloader.downloadFile(
                        from: tokenizerFileURL(filename), to: coreMLDir.appendingPathComponent(filename)
                    )
                }
            }
            let m = try await CoreMLASRModel.fromPretrained(
                cacheDir: coreMLDir
            ) { frac, stage in
                // fromPretrained's own `stage` string is static ("Downloading CoreML encoder...")
                // on every tick — no percent — which leaves the progress HUD frozen-looking for the
                // whole download (same fix as HTDemucs-FT's isolator download).
                progress?("\(stage) \(Int((frac * 100).rounded()))%")
            }
            model = m
            return m
        }
        if allCached { progress?("transcript fully cached — skipping ASR load") }

        var doneChunks = 0
        for (t0, t1) in pieces {
            // Each piece is a ~24s MLX forward pass; check between pieces so a mid-transcription
            // cancel (e.g. the user cancelling alignment) doesn't have to wait for every remaining
            // piece — up to ~30 in the worst case — to finish first.
            if cancellationCheck?() == true { throw CancellationError() }
            if let hit = cached[key(t0)] {
                keep(hit)   // resumed piece — no model work, no re-persist needed
            } else {
                let s = Int(t0 * sr), e = min(stem.count, Int(t1 * sr))
                if e > s {
                    let piece = Array(stem[s..<e])
                    let model = try await ensureModel()
                    // Using transcribe() (batched decoderPrefill), NOT transcribeBackgroundSafe()/
                    // transcribeWithoutMLX() — that path hit its own on-device SIGSEGV (EXC_BAD_ACCESS
                    // in CoreMLTextDecoder.audioEmbeddingFromMultiArray, an out-of-bounds read, distinct
                    // from the MLX bfloat16 crash Qwen3ASRModel had). transcribe() uses a completely
                    // different, well-exercised batched-prefill code path that doesn't call that
                    // function at all. It does touch a little MLX (audioEmbeds.asArray(Float.self)) for
                    // data transfer, not autoregressive generation — `withError` covers a
                    // handler-reported failure there; it can't cover a raw memory fault (nothing can).
                    // Protocol method: catches internally, returns "[CoreML error: ...]" on failure —
                    // the anchor-and-fill design tolerates an empty/unmatched piece either way.
                    var text = ((try? withError { model.transcribe(audio: piece, sampleRate: sampleRate, language: language) }) ?? "[CoreML error: withError caught an MLX failure]")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.hasPrefix("[CoreML error:") {
                        progress?("\(Int(t0))–\(Int(t1))s → \(text.prefix(80))")
                        text = ""
                    }
                    if text.isEmpty == false {
                        progress?("\(Int(t0))–\(Int(t1))s → \(text.prefix(16))")
                    }
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
