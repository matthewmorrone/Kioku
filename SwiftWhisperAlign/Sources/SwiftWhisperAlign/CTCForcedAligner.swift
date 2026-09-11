// CTCForcedAligner.swift
//
// On-device forced alignment via soniqo's Qwen3ForcedAligner (CTC). Replaces the
// Whisper cross-attention DTW path (ForcedAligner), which collapsed on full songs
// (~101 s median error vs the stable-ts oracle, 0% of lines within ±500 ms). CTC
// computes a monotonic alignment of the known text against per-frame token
// probabilities in a single forward pass, so it cannot "lose its place" the way the
// DTW timing-extraction hack did. Measured on the same fixture: ~3.9 s median on the
// vocal stem — a 26× improvement.
//
// The 0.6B model is downloaded on first use via fromPretrained() and cached in Application
// Support (see ModelStorage) — not in Caches, which iOS purges under storage pressure and
// leaves the next launch stranded on a partial download. Nothing is bundled in the binary.

import Foundation
import AVFoundation
import Qwen3ASR
import AudioCommon
import MLX

public struct CTCForcedAligner {
    public init() {}

    // Aligns lyric lines to the audio, returning one AlignedLine per input line. Pipeline:
    // isolate vocals (HTDemucs CoreML, cached per audio file) → one CTC forced-alignment pass
    // over the whole stem with the whole lyric → map units to lines.
    public func align(
        input: AlignmentInput,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        // Human-readable phase text for the UI ("Downloading vocal model… 45%",
        // "Isolating vocals… 2/6", "Aligning lyrics…"). The numeric onProgress alone
        // strands the UI at one value through the multi-minute download + separation;
        // this names the stage so the user sees motion and knows what's running.
        onStage: (@Sendable (String) -> Void)? = nil,
        onSegment: (@Sendable ([AlignedLine]) -> Void)? = nil
    ) async throws -> AlignmentResult {
        guard input.lines.isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No lyric lines to align."])
        }
        if cancellationCheck?() == true { throw CancellationError() }

        Self.breadcrumb("RUN START", reset: true)
        Self.breadcrumb("stem cache \(VocalStemCache.debugKeyInfo(for: input.audioURL))")

        // Bound MLX's retained buffer cache for the run. By default cacheLimit equals the (huge)
        // memoryLimit, so every buffer freed inside the aligner's forward pass is kept for reuse
        // instead of returned to the OS; over a full-song pass that retained pile is what pushes
        // the process past the jetsam line (confirmed 2026-09-11: same call survives with the
        // cap, is killed without it). Output-preserving — allocator retention only. A low cap
        // can't stall allocation; allocations just bypass the cache. Restored on exit.
        let priorCacheLimit = MLX.Memory.cacheLimit
        MLX.Memory.cacheLimit = 48 * 1024 * 1024
        defer { MLX.Memory.cacheLimit = priorCacheLimit }

        // Vocal isolation is the most expensive stage, and the isolated stem is a pure function
        // of the source audio — so a Re-align of unchanged audio loads the stem off disk and skips
        // both the stereo decode and the isolation, dropping in at the trim/VAD stage.
        let vocalMono: [Float]
        if let cached = VocalStemCache.load(for: input.audioURL) {
            Self.breadcrumb("vocal stem CACHE HIT \(cached.count) frames (~\(cached.count / 44_100)s)")
            onStage?("Loading cached vocals…")
            vocalMono = cached
        } else {
            onStage?("Decoding audio…")
            let stereo = try await Self.decodeStereoFloat(from: input.audioURL)
            guard stereo.count == 2, stereo[0].isEmpty == false else {
                throw NSError(domain: "SwiftWhisperAlign.CTC", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Audio decoded to zero frames."])
            }
            Self.breadcrumb("decoded stereo \(stereo[0].count) frames (~\(stereo[0].count / 44_100)s)")
            onProgress?(0.05)

            // Isolate vocals so the aligner sees speech-like audio rather than the full mix.
            // HTDemucs-FT via CoreML/ANE is the only separator; it runs a full song in ~1/3 the
            // wall time of the MLX build it replaced.
            onStage?("Isolating…")
            Self.breadcrumb("isolating (HTDemucs-FT CoreML/ANE)")
            let mono = try await HTDemucsCoreMLSeparator.isolateVocalsMono(
                stereo: stereo,
                cancellationCheck: cancellationCheck,
                onProgress: { frac in
                    onProgress?(0.10 + 0.30 * frac)                       // global bar
                    onStage?("Isolating… \(Int((frac * 100).rounded()))%")  // per-phase %
                },
                onStage: onStage
            )
            guard mono.isEmpty == false else {
                throw NSError(domain: "SwiftWhisperAlign.CTC", code: 15,
                              userInfo: [NSLocalizedDescriptionKey: "Vocal isolation produced no output."])
            }
            Self.breadcrumb("isolated voice \(mono.count) frames (HTDemucs CoreML)")
            VocalStemCache.store(mono, for: input.audioURL)
            Self.breadcrumb("vocal stem cached")
            vocalMono = mono
        }
        onProgress?(0.4)

        // Download (first use) + load the CTC aligner. Weights live in Application Support, not
        // the purgeable Caches dir — see ModelStorage.
        onStage?("Preparing aligner…")
        Self.breadcrumb("aligner: fromPretrained begin")
        let aligner = try await Qwen3ForcedAligner.fromPretrained(
            modelId: ModelStorage.forcedAlignerModelId,
            cacheDir: try ModelStorage.directory(for: ModelStorage.forcedAlignerModelId),
            progressHandler: { frac, stage in
                if stage.hasPrefix("Downloading") {
                    // The downloader reports 0…0.8 of the overall bar; rescale to a clean 0–100% of the
                    // download so the label reads as its own stage, not a stuttering "Preparing… 80%".
                    let pct = Int((min(frac, 0.8) / 0.8 * 100).rounded())
                    onStage?("Downloading aligner… \(pct)%")
                } else {
                    onStage?("Preparing aligner…")   // tokenizer + weight load: fast, no useful %
                }
                if stage.hasPrefix("Downloading weights") == false {
                    Self.breadcrumb("aligner-load: \(stage) \(Int((frac * 100).rounded()))%")
                }
            }
        )
        Self.breadcrumb("aligner loaded (fromPretrained returned)")
        if cancellationCheck?() == true { throw CancellationError() }

        // Sung regions on the stem (breaths/consonant gaps ≤3 s merged). Each region is aligned
        // separately, against only the slice of lines proportional to its share of the sung
        // duration (see `lineRangesByDuration`) — never the whole remaining lyric. Two problems
        // this avoids: a region's align() call never sees a long instrumental gap inside its
        // input (which parks lines on the wrong side of it), and it never sees the SAME lyric
        // text twice. That second one matters more than it sounds: a chorus that repeats later
        // in the song is a duplicate substring in the full lyric, and CTC alignment assumes a
        // strictly monotonic text→audio mapping — handed both repeats in one call, it has no way
        // to tell which occurrence it's hearing and can align a later repeat's words onto an
        // earlier repeat's audio (measured 2026-09-11: a song's final chorus, itself a near-exact
        // repeat of two earlier ones, landed 46-84 s early under whole-song alignment, spliced or
        // not — the failure tracked the duplicated text, not chunk boundaries or pass length).
        let regions = Self.mergeSegments(Self.energyVADSegments(vocalMono, sampleRate: 44_100), maxGap: 3.0)
        Self.breadcrumb("energy-VAD \(regions.count) regions: " + regions.prefix(12).map { String(format: "%.0f-%.0f", $0.start, $0.end) }.joined(separator: " "))
        onStage?("Aligning lyrics…")
        let totalSec = Double(vocalMono.count) / 44_100.0
        let chunkRegions = regions.isEmpty ? [(start: 0.0, end: totalSec)] : regions
        let lineRanges = Self.lineRangesByDuration(
            lines: input.lines, regionDurations: chunkRegions.map { $0.end - $0.start }
        )
        var units: [(start: Double, end: Double, text: String)] = []
        let pad = 0.25
        for (ri, region) in chunkRegions.enumerated() {
            let range = lineRanges[ri]
            guard range.end > range.start else { continue }
            let regionText = input.lines[range.start..<range.end].joined(separator: "\n")
            let s = max(0, region.start - pad)
            let e = min(totalSec, region.end + pad)
            let regionSamples = Array(vocalMono[Int(s * 44_100)..<min(vocalMono.count, Int(e * 44_100))])
            Self.breadcrumb("region \(ri + 1)/\(chunkRegions.count): \(Int(s))–\(Int(e))s, lines \(range.start + 1)–\(range.end) (\(regionText.count) chars)")
            let regionUnits = try Self.alignBySaturation(
                samples: regionSamples, sampleRate: 44_100, text: regionText, aligner: aligner,
                cancellationCheck: cancellationCheck
            )
            for u in regionUnits { units.append((u.start + s, u.end + s, u.text)) }
        }
        Self.breadcrumb("aligned \(units.count) units")
        onProgress?(0.9)

        // Decouple from the soniqo result type — pull starts/ends/texts into plain arrays.
        var unitStarts: [Double] = []
        var unitEnds: [Double] = []
        var unitTexts: [String] = []
        var lastEnd: Double = 0
        for unit in units {
            unitStarts.append(unit.start)
            unitEnds.append(unit.end)
            unitTexts.append(unit.text)
            lastEnd = max(lastEnd, unit.end)
        }

        let (lines, lineTokens) = Self.mapUnitsToLines(
            starts: unitStarts, ends: unitEnds, texts: unitTexts, lastEnd: lastEnd, lines: input.lines
        )

        onSegment?(lines)
        onProgress?(1.0)
        return AlignmentResult(lines: lines, lineTokens: lineTokens)
    }

    // Longest stretch of audio handed to one align() call — a safety net for the rare vocal
    // region that's long on its own (most are well under this). Two ceilings meet here: the
    // model's reliable range is ~270 s (past it the trailing words collapse onto one timestamp),
    // and on an iPhone 17 a 244 s call peaks ~1.3 GB while a 316 s call is jetsam-killed at the
    // ~3.4 GB per-process limit.
    //
    // NOTE: shrinking this to force more/earlier splits was tried (as the primary per-song
    // chunking mechanism, before regions were each scoped to their own disjoint lines) and made
    // things worse — measured 2026-09-11: 120 s cap on the same fixture, median 12.5 s vs 2.5 s,
    // coverage 5.9% vs 14.7%. A shorter window doesn't make the model say "this doesn't fit" more
    // often; it just silently compresses more text into whatever it's given, since the saturation
    // detector below only catches literal timestamp collapse, not gradual over-compression.
    private static let maxChunkSec = 200.0

    // Aligns `text` over `samples` in fixed maxChunkSec windows, letting the MODEL decide which
    // words belong to each window: every call gets all the not-yet-placed text, and words that
    // don't belong in that audio come back crammed onto one trailing timestamp (the aligner's
    // saturation signature). Everything before that plateau is kept, the audio cursor moves to
    // the last kept word, and the placed characters are dropped from the text. This is
    // speech-swift's own alignLong strategy with a memory-bounded first pass instead of a
    // whole-file one. `withError` turns MLX's internal fatalError handler into a catchable Swift
    // error. The caller scopes `samples`/`text` to one region and its own disjoint slice of
    // lines — this only has to sub-chunk when a single region overruns maxChunkSec.
    private static func alignBySaturation(
        samples: [Float], sampleRate: Int, text: String, aligner: Qwen3ForcedAligner,
        cancellationCheck: (@Sendable () -> Bool)?
    ) throws -> [(start: Double, end: Double, text: String)] {
        let totalSec = Double(samples.count) / Double(sampleRate)
        var results: [(start: Double, end: Double, text: String)] = []
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var chunkStart = 0.0
        var ci = 0
        while chunkStart < totalSec, remaining.isEmpty == false {
            if cancellationCheck?() == true { throw CancellationError() }
            let chunkEnd = min(totalSec, chunkStart + maxChunkSec)
            let isLast = chunkEnd >= totalSec
            let chunk = Array(samples[Int(chunkStart * Double(sampleRate))..<Int(chunkEnd * Double(sampleRate))])
            breadcrumb("align chunk \(ci + 1): \(Int(chunkStart))–\(Int(chunkEnd))s, \(remaining.count) chars left")
            let aligned = try withError { aligner.align(audio: chunk, text: remaining, sampleRate: sampleRate) }
            MLX.Memory.clearCache()
            ci += 1
            guard aligned.isEmpty == false else { chunkStart = chunkEnd; continue }

            let keepCount = isLast ? aligned.count : trailingPlateauStart(aligned, tolerance: 0.1, minSize: 5)
            let kept = aligned.prefix(keepCount)
            guard kept.isEmpty == false else { chunkStart = chunkEnd; continue }
            for w in kept {
                results.append((Double(w.startTime) + chunkStart, Double(w.endTime) + chunkStart, w.text))
            }
            if keepCount == aligned.count { break }

            // Drop the placed characters (non-whitespace count) from the text.
            let consumed = kept.reduce(0) { $0 + $1.text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 } }
            var dropped = 0
            var idx = remaining.startIndex
            while dropped < consumed, idx < remaining.endIndex {
                if remaining[idx].isWhitespace == false { dropped += 1 }
                idx = remaining.index(after: idx)
            }
            while idx < remaining.endIndex, remaining[idx].isWhitespace { idx = remaining.index(after: idx) }
            remaining = String(remaining[idx...])
            chunkStart = chunkEnd
        }

        return results
    }

    // Splits `lines` into one slice per region, snapping to whole-line boundaries so each
    // slice's share of characters tracks that region's share of the total sung duration. This is
    // an estimate, not a transcript — it only has to land close enough that no line (and so no
    // repeated chorus) ends up duplicated across two regions' align() calls.
    private static func lineRangesByDuration(
        lines: [String], regionDurations: [Double]
    ) -> [(start: Int, end: Int)] {
        guard regionDurations.isEmpty == false else { return [] }
        let charCounts = lines.map { $0.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 } }
        let totalChars = charCounts.reduce(0, +)
        let totalDur = regionDurations.reduce(0, +)
        guard totalChars > 0, totalDur > 0 else {
            return regionDurations.enumerated().map { i, _ in i == 0 ? (0, lines.count) : (lines.count, lines.count) }
        }
        var ranges: [(start: Int, end: Int)] = []
        var lineIdx = 0
        var charsSoFar = 0
        var durSoFar = 0.0
        for (i, d) in regionDurations.enumerated() {
            durSoFar += d
            let start = lineIdx
            if i == regionDurations.count - 1 {
                lineIdx = lines.count
            } else {
                let targetChars = Int((Double(totalChars) * durSoFar / totalDur).rounded())
                while lineIdx < lines.count, charsSoFar < targetChars {
                    charsSoFar += charCounts[lineIdx]
                    lineIdx += 1
                }
            }
            ranges.append((start, lineIdx))
        }
        return ranges
    }

    // Index of the first word in the trailing "stuck" plateau — ≥ `minSize` consecutive trailing
    // words whose start times differ by < `tolerance` — or `aligned.count` if none. Same detector
    // as speech-swift's alignLong.
    private static func trailingPlateauStart(_ aligned: [AlignedWord], tolerance: Float, minSize: Int) -> Int {
        let n = aligned.count
        guard n > minSize else { return n }
        var plateauStart = n
        for i in (1..<n).reversed() {
            if abs(aligned[i].startTime - aligned[i - 1].startTime) < tolerance {
                plateauStart = i - 1
            } else {
                break
            }
        }
        return (n - plateauStart) >= minSize ? plateauStart : n
    }

    // Isolated vocal stem (mono, 44.1 kHz) for `url` — from the shared on-disk cache when present
    // (alignment populates the same cache, so a song you've aligned transcribes for free), otherwise
    // isolated via HTDemucs CoreML and cached. Lets transcription feed the ASR clean vocals instead
    // of the full mix (the "26× improvement" the aligner relies on).
    public static func isolatedVocalStem(
        for url: URL,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [Float] {
        if let cached = VocalStemCache.load(for: url), cached.isEmpty == false { return cached }
        let stereo = try await decodeStereoFloat(from: url)
        guard stereo.count == 2, stereo[0].isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Audio decoded to zero frames."])
        }
        guard #available(iOS 16.0, macOS 13.0, *) else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 16,
                          userInfo: [NSLocalizedDescriptionKey: "Vocal isolation needs iOS 16 or later."])
        }
        let mono = try await HTDemucsCoreMLSeparator.isolateVocalsMono(
            stereo: stereo, cancellationCheck: cancellationCheck, onProgress: onProgress)
        guard mono.isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 15,
                          userInfo: [NSLocalizedDescriptionKey: "Vocal isolation produced no output."])
        }
        VocalStemCache.store(mono, for: url)
        return mono
    }

    // Maps the aligner's per-unit (start, end, text) output onto the input lines by accumulating
    // non-whitespace characters: a line's start is the start time of the unit covering its first
    // character. A line's end is its LAST sung character's end time, capped at the next line's start
    // — so a line that finishes well before the next one (a real instrumental gap) keeps its true
    // short end, leaving a gap that ♪ markers can fill rather than absorbing the interlude.
    private static func mapUnitsToLines(
        starts: [Double],
        ends: [Double],
        texts: [String],
        lastEnd: Double,
        lines: [String]
    ) -> (lines: [AlignedLine], lineTokens: [[AlignedToken]]) {
        func nonWS(_ s: String) -> Int { s.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 } }

        // Per non-WS character, in text order: the covering unit's start time, end time, and index.
        // (Whitespace carries no time of its own — it inherits position only.)
        var charTime: [Double] = []
        var charEnd: [Double] = []
        var charUnit: [Int] = []
        for (i, t) in texts.enumerated() {
            let n = nonWS(t)
            if n > 0 {
                charTime.append(contentsOf: repeatElement(starts[i], count: n))
                charEnd.append(contentsOf: repeatElement(ends[i], count: n))
                charUnit.append(contentsOf: repeatElement(i, count: n))
            }
        }

        // Each line's start time (its first char's unit start) and real end (its LAST char's unit end).
        var lineStarts: [Double] = []
        var lineEnds: [Double] = []
        var cum = 0
        for line in lines {
            let nw = nonWS(line)
            let s = charTime.isEmpty ? 0 : charTime[min(cum, charTime.count - 1)]
            let lastIdx = cum + nw - 1
            let e = (charEnd.isEmpty || nw == 0) ? s : charEnd[min(max(0, lastIdx), charEnd.count - 1)]
            lineStarts.append(s)
            lineEnds.append(e)
            cum += nw
        }

        var result: [AlignedLine] = []
        var lineTokens: [[AlignedToken]] = []
        var g = 0   // running non-WS char index across all lines, into charTime/charUnit
        for (i, line) in lines.enumerated() {
            let start = lineStarts[i]
            // End = the line's real sung end, with two corrections for the sung-text-on-speech-CTC
            // mismatch:
            //   (1) perceptualOffset: CTC peaks lag the perceptual end of singing by ~150–250 ms
            //       even on short phonemes — the model marks a phoneme transition, not the moment
            //       a listener hears the syllable stop. Apply unconditionally.
            //   (2) sustainedVowelGap: when the gap between this line's CTC end and the next
            //       line's start is up to ~4 s, that's a held final vowel + breath, not a real
            //       instrumental break. Absorb the gap so the highlight stays on the syllable
            //       being held. Larger gaps stay exposed for ♪ insertion.
            // The 9 s safety cap remains.
            let sustainedVowelGap = 4.0    // s; gaps up to this absorbed into the prior line
            let bridgeMargin = 0.05        // s; visual breathing room before the next line takes over
            let perceptualOffset = 0.20    // s; flat shift to compensate for CTC peak vs. heard end
            let nextBound = (i + 1 < lines.count) ? lineStarts[i + 1] : lastEnd
            let ctcEnd = lineEnds[i] + perceptualOffset
            let gapAfter = nextBound - ctcEnd
            let extendedEnd = (gapAfter > 0 && gapAfter <= sustainedVowelGap)
                ? nextBound - bridgeMargin
                : ctcEnd
            var end = max(start + 0.3, min(extendedEnd, nextBound, start + 9.0))

            // Sub-line checkpoints: walk the line's characters tracking the UTF-16 offset, group
            // consecutive non-WS chars that share an aligner unit, and emit one token per unit at
            // its first char's offset. Whitespace advances the offset but never opens a token, so
            // offsets/lengths are exact UTF-16 spans into the line → drop straight onto CueCharTiming.
            var tokens: [AlignedToken] = []
            if charTime.isEmpty == false {
                var off = 0, curUnit = -1, tokOff = 0, tokEnd = 0
                var tokStart = 0.0
                func flush() {
                    if tokEnd > tokOff {
                        tokens.append(AlignedToken(start: tokStart, charOffsetUTF16: tokOff, charLengthUTF16: tokEnd - tokOff))
                    }
                }
                for ch in line {
                    let w = String(ch).utf16.count
                    if ch.isWhitespace { off += w; continue }
                    let gi = min(g, charTime.count - 1)
                    let u = charUnit[gi]
                    if u != curUnit { flush(); curUnit = u; tokStart = charTime[gi]; tokOff = off; tokEnd = off }
                    off += w; tokEnd = off; g += 1
                }
                flush()
            }

            result.append(AlignedLine(text: line, start: start, end: end))

            // Keep the aligner's REAL per-word times — they track the actual singing, so the
            // highlight doesn't run ahead of the voice (an even char-rate redistribution did, since
            // singing isn't evenly paced). Only enforce a small minimum gap, which separates CTC
            // frame-quantization clusters (several words stamped within a few ms, then a hold) into
            // distinct visible moments while leaving real held-note gaps intact. Forward-only,
            // clamped to the line end.
            if tokens.count > 1 {
                let minGap = 0.1
                for t in 1..<tokens.count {
                    let want = tokens[t - 1].start + minGap
                    if tokens[t].start < want {
                        tokens[t] = AlignedToken(start: min(want, end),
                                                 charOffsetUTF16: tokens[t].charOffsetUTF16,
                                                 charLengthUTF16: tokens[t].charLengthUTF16)
                    }
                }
            }
            lineTokens.append(tokens)
        }
        return (result, lineTokens)
    }


    // Energy-based voice-activity detection on the (clean) vocal stem: returns the sung
    // regions in seconds, split at instrumental gaps. Builds a smoothed RMS envelope, gates at
    // a fraction of the stem's own loud-vocal level (95th-pct), and groups frames above the
    // gate into runs (tolerating sub-`minGapMs` dips within a phrase). Unlike a speech VAD,
    // sustained sung vowels keep energy up, so phrases stay whole instead of fragmenting.
    private static func energyVADSegments(
        _ samples: [Float], sampleRate: Int,
        gateFraction: Float = 0.2, minSpeechMs: Int = 300, minGapMs: Int = 350
    ) -> [(start: Double, end: Double)] {
        guard samples.count > sampleRate / 5 else { return [] }
        let frameLen = max(1, sampleRate / 50)   // 20 ms
        var env: [Float] = []
        env.reserveCapacity(samples.count / frameLen + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + frameLen, samples.count)
            var sum: Float = 0; var j = i
            while j < end { sum += samples[j] * samples[j]; j += 1 }
            env.append((sum / Float(end - i)).squareRoot())
            i = end
        }
        // ~0.3 s centered smooth so brief transients don't fragment a phrase.
        let half = max(1, (sampleRate / frameLen) / 6)
        var sm = [Float](repeating: 0, count: env.count)
        for k in 0..<env.count {
            let lo = max(0, k - half), hi = min(env.count - 1, k + half)
            var s: Float = 0; for m in lo...hi { s += env[m] }
            sm[k] = s / Float(hi - lo + 1)
        }
        let sorted = sm.sorted()
        let ref = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        guard ref > 0 else { return [] }
        let gate = ref * gateFraction
        let fps = max(1, sampleRate / frameLen)
        let minSpeech = max(1, fps * minSpeechMs / 1000)
        let minGap = max(1, fps * minGapMs / 1000)

        var segs: [(start: Double, end: Double)] = []
        var k = 0
        while k < sm.count {
            if sm[k] > gate {
                let startF = k
                var endF = k, gap = 0, j = k
                while j < sm.count {
                    if sm[j] > gate { endF = j; gap = 0 }
                    else { gap += 1; if gap >= minGap { break } }
                    j += 1
                }
                if endF - startF + 1 >= minSpeech {
                    // NOTE: a Schmitt-trigger start-backoff (like trimLeadingSilence) is NOT safe
                    // here. Mid-song, the audio before a segment is an instrumental break, not
                    // silence — its bleed keeps energy above any low floor, so a backoff walks the
                    // start all the way back across the break and pulls a post-gap line ~16–25 s
                    // early (measured). The intro is genuinely silent, so the trim's backoff is
                    // safe; these interior onsets are not. Keep the gated start.
                    segs.append((Double(startF * frameLen) / Double(sampleRate),
                                 Double((endF + 1) * frameLen) / Double(sampleRate)))
                }
                k = j + 1
            } else { k += 1 }
        }
        return segs
    }

    // Merges VAD segments separated by short gaps (within-phrase breaths) so we align over
    // coherent vocal regions instead of over-fragmenting, while still breaking at the real
    // instrumental gaps. Returns (start,end) seconds, sorted.
    private static func mergeSegments(_ segs: [(start: Double, end: Double)], maxGap: Double = 0.6) -> [(start: Double, end: Double)] {
        let sorted = segs.sorted { $0.start < $1.start }
        var merged: [(start: Double, end: Double)] = []
        for s in sorted {
            if var last = merged.last, s.start - last.end <= maxGap {
                last.end = max(last.end, s.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    // Decodes any audio file to 44.1 kHz stereo 32-bit float PCM via AVAssetReader
    // (the format OpenUnmix source separation expects). Deinterleaves into [left, right].
    private static func decodeStereoFloat(from url: URL) async throws -> [[Float]] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "No audio track in the selected file."])
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "Could not configure audio reader."])
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "SwiftWhisperAlign.CTC", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "Audio reader failed to start."])
        }
        var left: [Float] = []
        var right: [Float] = []
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var dataLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &dataLength, dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer, dataLength > 0 else { continue }
            let count = dataLength / MemoryLayout<Float>.size
            let fp = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            var i = 0
            while i + 1 < count { left.append(fp[i]); right.append(fp[i + 1]); i += 2 }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "SwiftWhisperAlign.CTC", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "Audio reader failed while decoding."])
        }
        return [left, right]
    }

}
