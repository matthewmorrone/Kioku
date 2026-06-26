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
import SourceSeparation
import MLX

public struct CTCForcedAligner {
    // Qwen3ForcedAligner expects 24 kHz mono float audio.
    private static let sampleRate = 24_000

    // Vocal-separation ("stemming") toggle. When false, the raw mix is fed straight to the
    // aligner — no separation — to confirm the forced-alignment stage works on its own.
    // When true, vocals are isolated via Apple's AUSoundIsolation (Neural Engine).
    private static let stemmingEnabled = true

    // Route alignment through VAD-gated segment windows (true) vs continuous sliding windows
    // (false). Kept true: the A/B showed continuous windowing UNDER-FEEDS — its char-rate is
    // diluted by instrumental time (totalChars / totalSec instead of / totalVocalSec), so it
    // strands the song's last lines (ran out of audio with 40 chars unplaced). VAD-gating's
    // vocal-only rate calibration is load-bearing. (Flag retained to re-run the A/B cheaply.)
    private static let vadGatingEnabled = true

    // Anchor-and-fill from TRANSCRIPTION anchors. The fill engine (alignAnchored) is correct: a line
    // next to a good anchor lands within 0.16s. The first attempt regressed because the anchor SOURCE
    // — VAD-gated StreamingASR — was front-loaded (Silero drops sustained back-half vowels), so no
    // anchors reached the back where the catastrophes are. Now we transcribe in fixed PIECES over the
    // energy-VAD regions (no Silero in the path), forcing whole-song coverage. See StemTranscriber.
    private static let anchorFillEnabled = true

    public init() {}

    // Writes a timestamped breadcrumb + remaining memory budget to
    // <Documents>/ctc-debug.log. Survives a hard SIGKILL (file is flushed each call),
    // so the LAST line pinpoints which stage was running when the OS killed the app,
    // and the availMem trend shows whether it's a memory exhaustion. Best-effort; never
    // throws. `reset:true` starts a fresh log for the run.
    private static func breadcrumb(_ stage: String, reset: Bool = false) {
        #if os(iOS)
        let availMB = Int(os_proc_available_memory()) / (1024 * 1024)
        #else
        let availMB = -1
        #endif
        let line = "[\(Date())] \(stage) | availMem=\(availMB)MB\n"
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = line.data(using: .utf8) else { return }
        let url = dir.appendingPathComponent("ctc-debug.log")
        if reset || FileManager.default.fileExists(atPath: url.path) == false {
            try? data.write(to: url)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    // [DEBUG] Writes mono float samples to <Documents>/<name> as a 16-bit PCM WAV. Used to
    // dump the isolated vocal stem so it can be played/inspected from the Files app (the app
    // has UIFileSharingEnabled). Best-effort; never throws.
    private static func saveDebugWAV(_ samples: [Float], sampleRate: Double, name: String) {
        guard samples.isEmpty == false,
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: samples.count) }
        try? file.write(from: buf)
    }

    // [PROBE] Samples os_proc_available_memory() on a background thread between start() and
    // stopMinMB(), tracking the MINIMUM seen — i.e. the peak memory pressure during a blocking
    // align() pass (which a single post-call sample misses, since GPU.clearCache() frees it first).
    private final class PeakMemTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var minAvailBytes = UInt.max
        private var running = false

        // Begins sampling on a detached thread; resets the running minimum.
        func start() {
            lock.lock(); minAvailBytes = .max; running = true; lock.unlock()
            Thread.detachNewThread { [weak self] in
                while true {
                    guard let self else { return }
                    self.lock.lock(); let go = self.running; self.lock.unlock()
                    if go == false { return }
                    #if os(iOS)
                    let a = UInt(os_proc_available_memory())
                    self.lock.lock(); if a < self.minAvailBytes { self.minAvailBytes = a }; self.lock.unlock()
                    #endif
                    usleep(50_000)   // 50 ms
                }
            }
        }

        // Stops sampling and returns the peak pressure (lowest available memory) in MB.
        func stopMinMB() -> Int {
            lock.lock(); running = false; let m = minAvailBytes; lock.unlock()
            return Int(m / (1024 * 1024))
        }
    }


    // Aligns lyric lines to the audio, returning one AlignedLine per input line.
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

        // JETSAM FIX (confirmed via on-device SIGKILL/EXC_CRASH + ctc-debug.log): bound MLX's
        // retained GPU buffer cache for the whole run. By default MLX's cacheLimit equals its
        // (very large) memoryLimit, so buffers freed after each ASR/aligner forward pass are
        // RETAINED for reuse rather than returned to the OS — on-device this showed as ~800MB
        // that never came back after the first transcription piece, steadily eating the jetsam
        // headroom os_proc_available_memory() reports until a forward-pass spike crossed the
        // limit and the OS killed us mid-StemTranscriber. Capping the cache forces those buffers
        // back to the OS between passes (per-piece clearCache() still runs), lowering peak
        // footprint. This is output-preserving: it changes only allocator retention, never any
        // computation. Unlike memoryLimit, a low cacheLimit cannot stall allocation — allocations
        // simply bypass the cache and hit the OS directly. Restored on exit so we don't perturb
        // any other in-process MLX user.
        let priorCacheLimit = MLX.Memory.cacheLimit
        MLX.Memory.cacheLimit = 48 * 1024 * 1024   // 48 MB — small cap; MLX docs note even ~2MB rarely hurts throughput
        defer { MLX.Memory.cacheLimit = priorCacheLimit }
        Self.breadcrumb("MLX cacheLimit \(priorCacheLimit / (1024 * 1024))MB→48MB · active=\(MLX.Memory.activeMemory / (1024 * 1024))MB cache=\(MLX.Memory.cacheMemory / (1024 * 1024))MB")

        // Vocal isolation is the most expensive and memory-hungry stage (the HTDemucs CoreML pass
        // below — several seconds and the jetsam cliff on the A17), yet the isolated stem is a pure
        // function of the source audio. So before decoding + isolating, consult the on-disk stem
        // cache: a Re-align of unchanged audio loads the stem straight off disk and skips BOTH the
        // stereo decode and the isolation, dropping in at the trim/VAD stage. Only the stemming-on
        // path is cacheable (the raw-mix branch has nothing to isolate).
        let vocalMono: [Float]
        if Self.stemmingEnabled, let cached = VocalStemCache.load(for: input.audioURL) {
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
            //
            // SEPARATOR = OpenUnmix. HTDemucs-FT isolates better (it produced the clean Mac stem), but
            // it SIGKILLs the app ~1 s into the first separate() on the A17 GPU — an MLX/Metal op in
            // its forward pass faults on device. Confirmed exhaustively: int8 AND fp16, 30 s AND 183 s
            // chunks, all with ~2.6–3 GB free, foreground, uncatchable (no signal). OpenUnmix is the
            // separator that runs to completion on-device. Its weaker isolation leaves some
            // instrumental bleed, which the adaptive trimLeadingSilence gate below is tuned to absorb.
            //
            // To restore HTDemucs once soniqo's Metal path is device-safe — or to run separation on
            // the Mac bridge and fetch the stem — swap the load+separate below for
            // HTDemucsSeparator.fromPretrained(precision:) + Self.separateVocalsChunked(...) (that
            // chunked helper, which bounds peak memory, is still defined below).
            if Self.stemmingEnabled {
                // Isolate vocals with Apple's AUSoundIsolation (Neural Engine) — the engine behind
                // Apple Music Sing. Native, on-device, iOS 16.2+; no model, no Metal crash, no
                // license question. (OpenUnmix/HTDemucs paths removed; see git history + the CoreML
                // spike notes if Apple's isolation quality proves insufficient.)
                onStage?("Isolating vocals…")
                Self.breadcrumb("isolating (HTDemucs CoreML)")
                let mono: [Float]
                if #available(iOS 16.0, macOS 13.0, *) {
                    mono = try HTDemucsCoreMLSeparator.isolateVocalsMono(
                        stereo: stereo,
                        cancellationCheck: cancellationCheck,
                        onProgress: { frac in
                            onProgress?(0.05 + 0.35 * frac)                       // global bar (legacy callers)
                            onStage?("Isolating vocals… \(Int((frac * 100).rounded()))%")  // per-phase %
                        }
                    )
                } else {
                    throw NSError(domain: "SwiftWhisperAlign.CTC", code: 16,
                                  userInfo: [NSLocalizedDescriptionKey: "Vocal isolation needs iOS 16 or later."])
                }
                guard mono.isEmpty == false else {
                    throw NSError(domain: "SwiftWhisperAlign.CTC", code: 15,
                                  userInfo: [NSLocalizedDescriptionKey: "Vocal isolation produced no output."])
                }
                Self.breadcrumb("isolated voice \(mono.count) frames (HTDemucs)")
                #if DEBUG
                // [DEBUG] Save the isolated stem so it can be played from Files → On My iPhone →
                // Kioku → isolated-vocal.wav to judge isolation quality + what's in the intro. Gated
                // out of release: it's a 19 MB write per align with no user-facing purpose.
                Self.saveDebugWAV(mono, sampleRate: 44_100, name: "isolated-vocal.wav")
                #endif
                // Persist the stem so the next Re-align of this exact audio skips isolation.
                VocalStemCache.store(mono, for: input.audioURL)
                Self.breadcrumb("vocal stem cached")
                vocalMono = mono
            } else {
                // Stemming OFF: downmix the raw stereo mix to mono and align on that directly.
                onStage?("Preparing audio…")
                let n = stereo[0].count
                var mono = [Float](repeating: 0, count: n)
                for i in 0..<n { mono[i] = (stereo[0][i] + stereo[1][i]) * 0.5 }
                Self.breadcrumb("stemming DISABLED — raw mix \(n) frames")
                vocalMono = mono
            }
        }
        onProgress?(0.4)

        // (a) Trim the leading instrumental-intro silence on the (now quiet) vocal stem so
        // the aligner doesn't pin the first line to 0:00. The lead is added back afterward.
        let (trimmedVocal, leadOffsetSec) = Self.trimLeadingSilence(vocalMono, sampleRate: 44_100)
        Self.breadcrumb("vocal mono \(trimmedVocal.count) frames, trimmed \(String(format: "%.1f", leadOffsetSec))s lead")

        // VAD: detect the sung segments across the whole stem so alignment windows snap to
        // vocal pauses and skip instrumental gaps (fixes the mid-song window-seam collapses and
        // the lines that stretched across instrumental breaks). ENERGY-based, not a speech VAD:
        // on the now-clean HTDemucs stem the vocal regions are exactly the loud spans and the
        // gaps are exactly the instrumental breaks — and energy survives sustained sung vowels
        // where a speech VAD (FireRedVAD) fragments. Empty → falls back to fixed windows.
        onStage?("Detecting vocals…")
        // The raw energy gate over-fragments a verse into 3–6 s slivers (breaths, consonant
        // gaps). Merge anything separated by ≤3 s back into one region so each alignment window
        // is a coherent vocal span; only the real instrumental gaps (≫3 s) stay as splits. This
        // is essential: a 6 s sliver handed to the CTC aligner crams the whole lyric into it.
        let vadRaw = Self.energyVADSegments(trimmedVocal, sampleRate: 44_100)
        let vadSegs = Self.mergeSegments(vadRaw, maxGap: 3.0)
        Self.breadcrumb("energy-VAD \(vadRaw.count)→\(vadSegs.count) segs: " +
                        vadSegs.prefix(12).map { String(format: "%.0f-%.0f", $0.start, $0.end) }.joined(separator: " "))

        // Anchor pass: transcribe the stem FIRST (before the aligner is loaded, so the ASR weights
        // are released before the aligner allocates), then mine confident line→time anchors from the
        // heard text. Falls back to an empty anchor set on any failure → routing uses VAD-gated.
        var anchors: [(line: Int, time: Double)] = []
        if Self.anchorFillEnabled {
            onStage?("Transcribing vocals for anchors…")
            let phrases = (try? await StemTranscriber.segments(
                stem: trimmedVocal, sampleRate: 44_100, regions: vadSegs,
                // Resumable checkpoint: a kill mid-transcription (the jetsam-prone stage) resumes from
                // the last completed piece instead of redoing the ~60 s load + every piece. Keyed by
                // audio identity, so it survives across app launches and is reused by later re-aligns.
                cacheIdentity: VocalStemCache.identityKey(for: input.audioURL),
                progress: { msg in
                    Self.breadcrumb("anchor-asr: \(msg)")
                    // The ASR model load is a ~60 s opaque step BEFORE any piece, so onFraction can't
                    // cover it — surface it explicitly so the label isn't frozen at a bare "…".
                    if msg.hasPrefix("loading") { onStage?("Transcribing vocals for anchors… (loading model)") }
                },
                // Per-phase % in the stage label, matching the isolation/alignment stages. Fires once
                // per ~24 s piece (so it starts at the first piece's fraction, never a stuck 0%).
                onFraction: { frac in
                    onStage?("Transcribing vocals for anchors… \(Int((frac * 100).rounded()))%")
                })) ?? []
            Self.breadcrumb("transcribed \(phrases.count) pieces over \(vadSegs.count) regions")
            anchors = Self.extractAnchors(lines: input.lines, phrases: phrases, vadSegs: vadSegs)
            MLX.GPU.clearCache()   // free the ASR model's GPU buffers before the aligner allocates
            Self.breadcrumb("anchors \(anchors.count)/\(input.lines.count): " +
                anchors.prefix(12).map { "L\($0.line)@\(String(format: "%.0f", $0.time))" }.joined(separator: " "))
            if cancellationCheck?() == true { throw CancellationError() }
        }

        // Downloads the CTC model on first use; cached thereafter in Application Support (not the
        // purgeable Caches dir — see ModelStorage). Surface the staged progress to the UI so this
        // isn't a frozen "Preparing alignment model…" through a ~400 MB download + weight load,
        // and breadcrumb the milestones (with availMem) so a run that dies here reveals WHETHER it
        // died mid-download (network) or mid-weight-load (memory). Skip the high-frequency
        // download-weights ticks.
        onStage?("Preparing alignment model…")
        Self.breadcrumb("aligner: fromPretrained begin")
        let aligner = try await Qwen3ForcedAligner.fromPretrained(
            modelId: ModelStorage.forcedAlignerModelId,
            cacheDir: try ModelStorage.directory(for: ModelStorage.forcedAlignerModelId),
            progressHandler: { frac, stage in
                if stage.hasPrefix("Downloading") {
                    // The downloader reports 0…0.8 of the overall bar; rescale to a clean 0–100% of the
                    // download so the label reads as its own stage, not a stuttering "Preparing… 80%".
                    let pct = Int((min(frac, 0.8) / 0.8 * 100).rounded())
                    onStage?("Downloading alignment model… \(pct)%")
                } else {
                    onStage?("Preparing alignment model…")   // tokenizer + weight load: fast, no useful %
                }
                // Breadcrumb milestones (with availMem) — skip the high-frequency download-weights ticks —
                // so a run that dies here shows WHETHER it died mid-download (network) or mid-load (memory).
                if stage.hasPrefix("Downloading weights") == false {
                    Self.breadcrumb("aligner-load: \(stage) \(Int((frac * 100).rounded()))%")
                }
            }
        )
        Self.breadcrumb("aligner loaded (fromPretrained returned)")
        if cancellationCheck?() == true { throw CancellationError() }

        onStage?("Aligning lyrics…")
        let text = input.lines.joined(separator: "\n")

        let alignProgress: (Double) -> Void = { frac in
            onProgress?(0.40 + 0.50 * frac)                        // global bar (legacy callers)
            onStage?("Aligning lyrics… \(Int((frac * 100).rounded()))%")   // per-phase %
        }
        let rawUnits: [(start: Double, end: Double, text: String)]
        if Self.anchorFillEnabled && anchors.count >= 2 {
            Self.breadcrumb("aligning (anchor-fill) \(input.lines.count) lines, \(anchors.count) anchors")
            rawUnits = Self.alignAnchored(
                samples: trimmedVocal, audioRate: 44_100, lines: input.lines, anchors: anchors,
                vadSegs: vadSegs, aligner: aligner, cancellationCheck: cancellationCheck, onProgress: alignProgress)
        } else if vadSegs.isEmpty || Self.vadGatingEnabled == false {
            Self.breadcrumb("aligning (windowed) \(text.count) chars over ~\(trimmedVocal.count / 44_100)s")
            rawUnits = Self.alignWindowed(
                samples: trimmedVocal, audioRate: 44_100, text: text, aligner: aligner,
                cancellationCheck: cancellationCheck, onProgress: alignProgress)
        } else {
            Self.breadcrumb("aligning (VAD-gated) \(text.count) chars over \(vadSegs.count) segments")
            rawUnits = Self.alignVADGated(
                samples: trimmedVocal, audioRate: 44_100, text: text, aligner: aligner,
                segments: vadSegs, cancellationCheck: cancellationCheck, onProgress: alignProgress)
        }
        alignProgress(1.0)   // windows report progress at their start; close the phase at a true 100%
        // Map back to the original timeline (undo the leading-silence trim).
        let units = rawUnits.map { (start: $0.start + leadOffsetSec, end: $0.end + leadOffsetSec, text: $0.text) }
        Self.breadcrumb("aligned \(units.count) units (\(vadSegs.isEmpty ? "windowed" : "VAD-gated"))")
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
        // Vocal regions in absolute song time (undo the leading-silence trim) — the caller marks
        // the gaps BETWEEN these as ♪, so markers track real silence on the stem, not cue-time slack.
        let vocalSegments = vadSegs.map { (start: $0.start + leadOffsetSec, end: $0.end + leadOffsetSec) }
        return AlignmentResult(lines: lines, lineTokens: lineTokens, vocalSegments: vocalSegments)
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
        let mono = try HTDemucsCoreMLSeparator.isolateVocalsMono(
            stereo: stereo, cancellationCheck: cancellationCheck, onProgress: onProgress)
        guard mono.isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 15,
                          userInfo: [NSLocalizedDescriptionKey: "Vocal isolation produced no output."])
        }
        VocalStemCache.store(mono, for: url)
        return mono
    }

    // Aligns and returns SRT text — drop-in for ForcedAligner.alignToSRT.
    public func alignToSRT(
        input: AlignmentInput,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onStage: (@Sendable (String) -> Void)? = nil,
        onSegment: (@Sendable ([AlignedLine]) -> Void)? = nil
    ) async throws -> String {
        let result = try await align(
            input: input,
            cancellationCheck: cancellationCheck,
            onProgress: onProgress,
            onStage: onStage,
            onSegment: onSegment
        )
        return SRTWriter.write(result)
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
        lines: [String],
        regularize: Bool = true
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
            var start = lineStarts[i]
            // End = the line's real sung end, but capped two ways: never past the next line's start,
            // and never longer than a plausible sung line (9 s). The cap matters across instrumental
            // gaps — the aligner stretches a line's last-word END across the following silence, so
            // without it a line before a 26 s interlude would absorb the whole gap and leave nothing
            // for ♪ insertion. No real sung line is 9 s, so the cap only fires before a long gap,
            // re-exposing it; normal lines keep their real (shorter) end.
            let nextBound = (i + 1 < lines.count) ? lineStarts[i + 1] : lastEnd
            var end = max(start + 0.3, min(lineEnds[i], nextBound, start + 9.0))

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

            // Straddle fix: a line's word times can't really span a 5s+ internal gap — no sung line
            // pauses that long mid-phrase. When they do, the line's tail spilled across an
            // instrumental break: the windowing ran out of segment audio for the last line before a
            // gap, so CTC placed the line's ONSET (the tokens before the gap) at its true start and
            // smeared the remaining tokens onto the far side. Keep the line on the onset side — cap
            // its end before the gap and pull the spilled tail tokens back to just after the onset —
            // so neither the line start nor the per-word sweep jumps the interlude (the 生きてゆく
            // +19s off-by-one). A clean line that genuinely begins after a gap has ALL its tokens on
            // the far side, so it never straddles and this never fires on it.
            if tokens.count > 1 {
                var gapIdx = 0
                var gapMax = 0.0
                for t in 1..<tokens.count {
                    let gp = tokens[t].start - tokens[t - 1].start
                    if gp > gapMax { gapMax = gp; gapIdx = t }
                }
                if gapMax > 5.0, gapIdx > 0 {
                    let onsetEnd = tokens[gapIdx - 1].start
                    end = max(start + 0.3, min(onsetEnd + 0.5, nextBound))
                    for t in gapIdx..<tokens.count {
                        let pulled = min(end, onsetEnd + 0.1 * Double(t - gapIdx + 1))
                        tokens[t] = AlignedToken(start: pulled,
                                                 charOffsetUTF16: tokens[t].charOffsetUTF16,
                                                 charLengthUTF16: tokens[t].charLengthUTF16)
                    }
                }
            }
            result.append(AlignedLine(text: line, start: start, end: end))

            // Keep the aligner's REAL per-word times — they track the actual singing, so the
            // highlight doesn't run ahead of the voice (an even char-rate redistribution did, since
            // singing isn't evenly paced). Only enforce a small minimum gap, which separates CTC
            // frame-quantization clusters (several words stamped within a few ms, then a hold) into
            // distinct visible moments while leaving real held-note gaps intact. Forward-only,
            // clamped to the line end. (`regularize` is retained on the signature for the disabled
            // pass-2 path; both paths now keep real timing.)
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
            _ = regularize
            lineTokens.append(tokens)
        }
        return (result, lineTokens)
    }


    // Separates vocals from a decoded stereo mix in bounded-length chunks so peak memory stays
    // under the jetsam limit (the call site explains why a single full-song separate() OOMs).
    // Each chunk runs through the full HTDemucs bag, is downmixed to mono, and the MLX buffer
    // cache is cleared before the next chunk allocates. Consecutive chunks overlap by `overlapSec`
    // and are linearly crossfaded so the seam is continuous (the model has no context across a
    // chunk boundary, so a hard cut would click). Returns full-length mono vocals at `sampleRate`,
    // or [] if separation produced nothing. Throws CancellationError if cancelled between chunks.
    private static func separateVocalsChunked(
        separator: HTDemucsSeparator,
        stereo: [[Float]],
        chunkSec: Double = 30,
        overlapSec: Double = 1,
        sampleRate: Int = 44_100,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onStage: ((String) -> Void)? = nil
    ) throws -> [Float] {
        guard stereo.count == 2 else { return [] }
        let left = stereo[0], right = stereo[1]
        let L = min(left.count, right.count)
        guard L > 0 else { return [] }

        let chunkLen = max(1, Int(chunkSec * Double(sampleRate)))
        let overlap = min(chunkLen / 2, max(0, Int(overlapSec * Double(sampleRate))))
        let stride = max(1, chunkLen - overlap)
        let totalChunks = max(1, (L + stride - 1) / stride)

        var vocalMono: [Float] = []
        vocalMono.reserveCapacity(L)

        var start = 0
        while start < L {
            if cancellationCheck?() == true { throw CancellationError() }
            let end = min(L, start + chunkLen)
            let n = end - start

            #if os(iOS)
            let availMB = Int(os_proc_available_memory()) / (1024 * 1024)
            #else
            let availMB = -1
            #endif

            // Planar [all-L, all-R] for this chunk → [1, 2, n], the layout separate() expects.
            var planar = [Float]()
            planar.reserveCapacity(2 * n)
            planar.append(contentsOf: left[start..<end])
            planar.append(contentsOf: right[start..<end])
            let mix = MLXArray(planar).reshaped([1, 2, n])

            onStage?("Isolating vocals… \(start / stride + 1)/\(totalChunks)")
            breadcrumb("→ separate() chunk @\(start / sampleRate)s n=\(n) availMem=\(availMB)MB")
            let stems = separator.separate(mix)
            breadcrumb("← separate() returned chunk @\(start / sampleRate)s")
            guard let vocalsArr = stems["vocals"] else {
                MLX.GPU.clearCache()
                start += stride
                continue
            }
            // [1, 2, n] row-major → first half = left, second half = right; downmix to mono.
            let vFlat = vocalsArr.asArray(Float.self)
            MLX.GPU.clearCache()   // chunk is now plain Swift values; release the buffer pool
            let half = vFlat.count / 2
            var chunkVocal = [Float](repeating: 0, count: half)
            for i in 0..<half { chunkVocal[i] = (vFlat[i] + vFlat[half + i]) * 0.5 }

            breadcrumb("sep chunk \(start / sampleRate)–\(end / sampleRate)s · \(half) frames · availMem=\(availMB)MB")

            if vocalMono.isEmpty {
                vocalMono.append(contentsOf: chunkVocal)
            } else {
                // Crossfade this chunk's head over the already-written overlap region (indexed
                // absolutely, so it stays aligned even for a short final chunk), then append the
                // remainder. `ov` = how many of this chunk's samples land on written audio.
                let ov = max(0, min(vocalMono.count - start, chunkVocal.count))
                for j in 0..<ov {
                    let t = Float(j) / Float(max(1, ov))
                    vocalMono[start + j] = vocalMono[start + j] * (1 - t) + chunkVocal[j] * t
                }
                if chunkVocal.count > ov {
                    vocalMono.append(contentsOf: chunkVocal[ov...])
                }
            }

            onProgress?(Double(end) / Double(L))
            if end >= L { break }
            start += stride
        }
        return vocalMono
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



    // Aligns text to audio gated by VAD segments: aligns text only WITHIN sung regions,
    // sub-windowing long ones, and treats each segment's end as a trustworthy boundary (a real
    // vocal pause) so the last line of a segment isn't squished — and skips instrumental gaps
    // entirely so no line stretches across silence. Returns units in absolute seconds.
    // Index of the first word in the trailing "stuck" plateau — ≥ `minSize` consecutive trailing
    // words whose start times differ by < `tol` — or `aligned.count` if none. That plateau is the
    // CTC saturation signature: the model ran out of reliable audio and the monotonicity pass
    // collapsed the leftover tokens onto the last anchor. Ported from the soniqo aligner's own
    // long-audio chunker; replaces the hand-rolled near-zero-duration cram guard.
    private static func trailingPlateauStart(_ units: [(start: Double, end: Double, text: String)], tol: Double, minSize: Int) -> Int {
        let n = units.count
        guard n > minSize else { return n }
        var plateauStart = n
        for i in (1..<n).reversed() {
            if abs(units[i].start - units[i - 1].start) < tol {
                plateauStart = i - 1
            } else {
                break
            }
        }
        return (n - plateauStart) >= minSize ? plateauStart : n
    }

    // One window's aligned units → the trustworthy prefix to keep. First drops the saturated tail
    // (the plateau) when `trimSaturation`, then — unless the window ends at a real vocal pause
    // (`keepToEdge`) — drops units past the window's boundary margin, which are legit but belong to
    // the next window. Always keeps ≥1 unit so the loop makes forward progress.
    private static func reliablePrefix(
        _ units: [(start: Double, end: Double, text: String)], windowDur: Double, boundaryMargin: Double,
        keepToEdge: Bool, trimSaturation: Bool
    ) -> [(start: Double, end: Double, text: String)] {
        guard units.isEmpty == false else { return [] }
        var kept = trimSaturation
            ? Array(units.prefix(trailingPlateauStart(units, tol: 0.1, minSize: 4)))
            : units
        if keepToEdge == false {
            let cutoff = windowDur - boundaryMargin
            while let last = kept.last, last.start >= cutoff { kept.removeLast() }
        }
        if kept.isEmpty { kept = [units[0]] }
        return kept
    }



    // Mines confident line→time anchors by matching each lyric line against each transcription
    // phrase by LONGEST CONTIGUOUS shared run — scattered single-char coincidences (which sank the
    // global-NW version, e.g. a spurious L14@10s) don't count; only a run of consecutive shared
    // chars (触れられない=6, 深い闇=3) does. The anchor time interpolates where the run falls inside
    // its phrase. We then keep the maximal run-WEIGHTED monotonic-in-time backbone, so a chain of
    // strong real anchors beats any stray weak match that doesn't fit the timeline.
    private static func extractAnchors(
        lines: [String], phrases: [(start: Double, end: Double, text: String)],
        vadSegs: [(start: Double, end: Double)]
    ) -> [(line: Int, time: Double)] {
        let keep: (Character) -> Bool = { $0.isWhitespace == false && $0.isPunctuation == false }
        let phraseChars: [(chars: [Character], t0: Double, t1: Double)] = phrases.compactMap {
            let c = Array($0.text.filter(keep)); return c.isEmpty ? nil : (chars: c, t0: $0.start, t1: $0.end)
        }
        guard phraseChars.isEmpty == false else { return [] }

        // Expected time per line: char-proportional position mapped over the vocal (VAD) timeline.
        // Drives BOTH the tie-break below (pick the piece nearest the lyric-position estimate, so a
        // line on the far side of a gap isn't walled onto the near side) and the chorus gate.
        let lineChars = lines.map { Double(max(1, $0.filter(keep).count)) }
        let totalChars = max(1, lineChars.reduce(0, +))
        var expected: [Double] = []
        if vadSegs.isEmpty == false {
            let segDur = vadSegs.map { max(0, $0.end - $0.start) }
            let totalVocal = max(1, segDur.reduce(0, +))
            let timeAtVocalFrac: (Double) -> Double = { f in
                var target = f * totalVocal
                for (i, seg) in vadSegs.enumerated() {
                    if target <= segDur[i] { return seg.start + target }
                    target -= segDur[i]
                }
                return vadSegs.last?.end ?? 0
            }
            expected = [Double](repeating: 0, count: lines.count)
            var cum = 0.0
            for i in 0..<lines.count { expected[i] = timeAtVocalFrac((cum + lineChars[i] / 2) / totalChars); cum += lineChars[i] }
        }

        // Per line: the strongest contiguous run against any phrase. On EQUAL run length, prefer the
        // phrase whose interpolated time is closest to the line's expected position — so a line that
        // matches two pieces equally (a coincidental early 2-char hit vs the real post-gap one) takes
        // the temporally-sensible one. A 2-char run is enough now; the tie-break + chorus gate +
        // run-weighted LIS keep junk out, and 2-char matches are needed to anchor short garbled lines
        // (e.g. 脆い爪先→目先) onto the correct side of an internal gap.
        var cands: [(line: Int, time: Double, run: Int)] = []
        for (li, line) in lines.enumerated() {
            let lc = Array(line.filter(keep))
            guard lc.count >= 2 else { continue }
            let exp: Double? = li < expected.count ? expected[li] : nil
            var best: (run: Int, time: Double, dist: Double)?
            for ph in phraseChars {
                let (run, endInB) = Self.longestCommonRun(lc, ph.chars)
                guard run >= 2 else { continue }
                let startB = max(0, endInB - run)                       // 0-based run start within phrase
                let frac = Double(startB) / Double(max(1, ph.chars.count))
                let t = ph.t0 + frac * max(0, ph.t1 - ph.t0)            // interpolate within the phrase
                let dist = exp.map { abs(t - $0) } ?? 0
                if best == nil || run > best!.run || (run == best!.run && dist < best!.dist) {
                    best = (run, t, dist)
                }
            }
            if let b = best { cands.append((line: li, time: b.time, run: b.run)) }
        }
        guard cands.isEmpty == false else { return [] }

        // Chorus-repetition gate: a repeated lyric ("…忘れない") can match the WRONG repetition and
        // teleport 50s. Drop any candidate grossly far (>28s) from its expected lyric-position.
        if expected.isEmpty == false {
            cands = cands.filter { abs($0.time - expected[$0.line]) <= 28.0 }
            guard cands.isEmpty == false else { return [] }
        }

        // Run-weighted longest-increasing-(time)-subsequence over candidates in line order.
        let cs = cands.sorted { $0.line < $1.line }
        let k = cs.count
        var w = cs.map { Double($0.run) }
        var parent = [Int](repeating: -1, count: k)
        for i in 0..<k {
            for j in 0..<i where cs[j].time < cs[i].time && w[j] + Double(cs[i].run) > w[i] {
                w[i] = w[j] + Double(cs[i].run); parent[i] = j
            }
        }
        var bi = 0
        for i in 1..<k where w[i] > w[bi] { bi = i }
        var chain: [Int] = []; var idx = bi
        while idx >= 0 { chain.append(idx); idx = parent[idx] }
        return chain.reversed().map { (line: cs[$0].line, time: cs[$0].time) }
    }

    // Longest run of consecutive equal characters shared by a and b. Returns the run length and the
    // (1-based, inclusive) end index of that run within b, so the caller can locate it inside b.
    private static func longestCommonRun(_ a: [Character], _ b: [Character]) -> (len: Int, endInB: Int) {
        guard a.isEmpty == false, b.isEmpty == false else { return (0, 0) }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var best = 0, bestEnd = 0
        for i in 1...a.count {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count where a[i - 1] == b[j - 1] {
                cur[j] = prev[j - 1] + 1
                if cur[j] > best { best = cur[j]; bestEnd = j }
            }
            prev = cur
        }
        return (best, bestEnd)
    }


    // Anchor-and-fill. The lines between two consecutive anchors are forced-aligned to the audio
    // between their times, so a wrong char-rate guess can't drift a line PAST an anchor. Reuses
    // alignVADGated per span (windows + respects VAD gaps within, with the span's OWN char-rate, and
    // no song-long tail). Head covers lines before the first anchor; the final span gets the tail.
    private static func alignAnchored(
        samples: [Float], audioRate: Int, lines: [String],
        anchors: [(line: Int, time: Double)],
        vadSegs: [(start: Double, end: Double)],
        aligner: Qwen3ForcedAligner,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) -> [(start: Double, end: Double, text: String)] {
        let n = lines.count
        let totalSec = Double(samples.count) / Double(audioRate)
        let firstVocal = vadSegs.first?.start ?? 0
        let lastVocal = max(vadSegs.last?.end ?? totalSec, anchors.last?.time ?? totalSec)
        let sorted = anchors.sorted { $0.line < $1.line }

        // (lineStart, lineEnd, t0, t1) spans: optional head, then between each anchor and the next.
        var spans: [(ls: Int, le: Int, t0: Double, t1: Double)] = []
        if let first = sorted.first, first.line > 0 { spans.append((0, first.line, firstVocal, first.time)) }
        for k in 0..<sorted.count {
            let ls = sorted[k].line
            let le = k + 1 < sorted.count ? sorted[k + 1].line : n
            let t1 = k + 1 < sorted.count ? sorted[k + 1].time : lastVocal
            if le > ls { spans.append((ls, le, sorted[k].time, t1)) }
        }

        var results: [(start: Double, end: Double, text: String)] = []
        for (si, sp) in spans.enumerated() {
            if cancellationCheck?() == true { break }
            let isLast = si == spans.count - 1
            let segText = lines[sp.ls..<sp.le].joined(separator: "\n")
            // VAD gaps within this span (skip instrumental); fall back to the whole span.
            let inside = vadSegs.compactMap { v -> (start: Double, end: Double)? in
                let s = max(v.start, sp.t0), e = min(v.end, sp.t1)
                return e - s > 0.2 ? (start: s, end: e) : nil
            }
            let span = inside.isEmpty ? [(start: sp.t0, end: sp.t1)] : inside
            Self.breadcrumb("anchor-seg \(si): lines \(sp.ls)–\(sp.le - 1) in " +
                            "\(String(format: "%.0f–%.0f", sp.t0, sp.t1))s (\(span.count) vad)")
            let units = Self.alignVADGated(
                samples: samples, audioRate: audioRate, text: segText, aligner: aligner,
                segments: span, appendTail: isLast,
                cancellationCheck: cancellationCheck, onProgress: nil)
            results.append(contentsOf: units)
            onProgress?(Double(si + 1) / Double(max(1, spans.count)))
        }
        return results
    }

    private static func alignVADGated(
        samples: [Float],
        audioRate: Int,
        text: String,
        aligner: Qwen3ForcedAligner,
        segments: [(start: Double, end: Double)],
        windowSec: Double = 30,
        appendTail: Bool = true,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) -> [(start: Double, end: Double, text: String)] {
        let sr = Double(audioRate)
        let totalSec = Double(samples.count) / sr
        let boundaryMargin = 1.5

        // Ensure any text the VAD missed still has audio to land on: append a tail region. Disabled
        // for anchor-bounded spans, whose text must stay inside [t0,t1] (a tail to song-end would let
        // a span's trailing line escape its anchor wall).
        var segs = segments.filter { $0.end > $0.start }
        if appendTail, let last = segs.last, last.end < totalSec - 1.0 { segs.append((last.end, totalSec)) }
        if segs.isEmpty { segs = [(0, totalSec)] }

        var results: [(start: Double, end: Double, text: String)] = []
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Progress is the fraction of LYRIC TEXT placed, not audio swept: the run ends when the
        // text is exhausted (often well before the final segment), so a vocal-swept metric stalls
        // partway then jumps. Text-consumed rises to a true 100% exactly when alignment finishes.
        let totalChars = max(1, remaining.count)
        // The song's OWN average char-rate (total lyric chars ÷ total vocal seconds) — self-
        // calibrating, replacing the old global maxSungCharsPerSec constant. Used only to bound how
        // much text each window is fed; the plateau detector does the actual cram trimming.
        let totalVocalSec = max(1.0, segments.reduce(0.0) { $0 + ($1.end - $1.start) })
        let songCharsPerSec = Double(remaining.count) / totalVocalSec

        // No hard per-segment text budget. The tight 1.0× feed below already paces consumption to
        // ~each segment's duration-proportional share per window, and every segment is processed to
        // its own vocal pause (segEnd) — so a segment finishes its OWN audio rather than having a
        // budget cap cut its last line short and spill it across the next instrumental gap.
        for (segIdx, seg) in segs.enumerated() {
            if remaining.isEmpty { break }
            let isLastSeg = segIdx == segs.count - 1
            var audioStart = seg.start
            let segEnd = min(seg.end, totalSec)
            var iter = 0
            let maxIter = Int((segEnd - seg.start) / 2.0) + 16
            while audioStart < segEnd - 0.3 && remaining.isEmpty == false && iter < maxIter {
                iter += 1
                if cancellationCheck?() == true { break }
                let windowEnd = min(audioStart + windowSec, segEnd)
                let windowDur = windowEnd - audioStart
                let isSegTail = windowEnd >= segEnd - 0.01
                let startIdx = Int(audioStart * sr)
                let endIdx = min(samples.count, Int(windowEnd * sr))
                guard endIdx > startIdx else { break }
                let window = Array(samples[startIdx..<endIdx])

                breadcrumb("vad win \(Int(audioStart))–\(Int(windowEnd))s · \(remaining.count) chars left")
                onProgress?(Double(totalChars - remaining.count) / Double(totalChars))
                // Feed ~1× the window's expected content (its duration × the song's own measured
                // char-rate). TIGHT on purpose, and load-bearing: over-feeding (tried 1.5×) makes
                // CTC SPREAD the overflow across the window with distinct compressed start-times —
                // NOT the equal-time pile the plateau detector looks for — so the excess slips past
                // every guard and gets committed early, cramming the whole back half forward (median
                // jumped to ~35 s). alignLong over-feeds safely only because its chunks are long
                // enough that the excess is a tiny fraction; at a 30 s window it's a flood.
                let feedChars = max(24, Int(windowDur * songCharsPerSec))
                let fedText = remaining.count > feedChars ? String(remaining.prefix(feedChars)) : remaining
                let aligned = aligner.align(audio: window, text: fedText, sampleRate: audioRate)
                MLX.GPU.clearCache()
                if aligned.isEmpty { audioStart = windowEnd; continue }
                let units = aligned.map { (start: Double($0.startTime), end: Double($0.endTime), text: $0.text) }

                // Keep the trustworthy prefix: drop the saturated (crammed) tail and the units past
                // the boundary margin so they retry in the next overlapping window — EXCEPT at a
                // segment tail. There the "next window" is across a real instrumental gap, so a
                // trimmed line isn't deferred, it's exiled to the far side of the break (the
                // 生きてゆく +19s off-by-one). At a seg tail we keep the whole fed span — both the
                // boundary tail (keepToEdge) and the saturated tail (no trimSaturation) — so the
                // segment's last lines stay in the segment that actually holds their audio.
                let reliable = reliablePrefix(
                    units, windowDur: windowDur, boundaryMargin: boundaryMargin,
                    keepToEdge: isSegTail, trimSaturation: isLastSeg == false && isSegTail == false
                )
                for u in reliable { results.append((u.start + audioStart, u.end + audioStart, u.text)) }

                // Advance text past the consumed units (non-whitespace char count).
                let consumedNonWS = reliable.reduce(0) { acc, u in acc + u.text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 } }
                var dropped = 0
                var idx = remaining.startIndex
                while dropped < consumedNonWS && idx < remaining.endIndex {
                    if remaining[idx].isWhitespace == false { dropped += 1 }
                    idx = remaining.index(after: idx)
                }
                while idx < remaining.endIndex && remaining[idx].isWhitespace { idx = remaining.index(after: idx) }
                remaining = String(remaining[idx...])
                onProgress?(Double(totalChars - remaining.count) / Double(totalChars))   // bump as text is placed

                if isSegTail { break }   // consumed this segment to its pause
                let lastEndAbs = (reliable.last?.end ?? windowDur) + audioStart
                audioStart = max(lastEndAbs, audioStart + 3.0)
            }
        }
        return results
    }

    // Drives align() over short audio windows so peak memory stays bounded — a single
    // full-song pass allocates multi-GB encoder attention and is jetsam-killed on device
    // (confirmed: crash inside align() with 2.7 GB still free). Each window aligns the
    // remaining text; only units landing comfortably inside the window are kept (units
    // crammed at the window edge belong to later audio and are retried in the next
    // window, so nothing is dropped). Returns units in absolute seconds.
    private static func alignWindowed(
        samples: [Float],
        audioRate: Int,
        text: String,
        aligner: Qwen3ForcedAligner,
        windowSec: Double = 30,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) -> [(start: Double, end: Double, text: String)] {
        let sr = Double(audioRate)
        let totalSec = Double(samples.count) / sr
        let boundaryMargin = 2.0   // units ending within this of the window edge are unreliable

        var results: [(start: Double, end: Double, text: String)] = []
        var audioStart = 0.0
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalChars = max(1, remaining.count)   // progress = lyric text placed (see alignVADGated)
        // Self-calibrated feed rate (no VAD here, so denominator is the whole audio span).
        let songCharsPerSec = Double(remaining.count) / max(1.0, totalSec)
        var iter = 0
        let maxIter = Int(totalSec / 5.0) + 64   // progress is ≥5s/iter; generous safety cap

        while audioStart < totalSec - 0.5 && remaining.isEmpty == false && iter < maxIter {
            iter += 1
            if cancellationCheck?() == true { break }

            let windowEnd = min(audioStart + windowSec, totalSec)
            let windowDur = windowEnd - audioStart
            let isLast = windowEnd >= totalSec - 0.01
            let startIdx = Int(audioStart * sr)
            let endIdx = min(samples.count, Int(windowEnd * sr))
            guard endIdx > startIdx else { break }
            let window = Array(samples[startIdx..<endIdx])

            breadcrumb("window \(Int(audioStart))–\(Int(windowEnd))s · \(remaining.count) chars left")
            onProgress?(Double(totalChars - remaining.count) / Double(totalChars))   // lyric text placed
            // Generous self-calibrated feed (see alignVADGated); plateau detector trims any cram.
            let feedChars = max(24, Int(windowDur * songCharsPerSec * 1.0))
            let fedText = remaining.count > feedChars ? String(remaining.prefix(feedChars)) : remaining
            let aligned = aligner.align(audio: window, text: fedText, sampleRate: audioRate)
            // Release MLX's buffer cache from this pass — it grows unbounded across
            // align() calls otherwise (memory marched 2749→743→226 MB → OOM). align()
            // has already evaluated, so the result is plain values; nothing live is freed.
            MLX.GPU.clearCache()
            if aligned.isEmpty { audioStart = windowEnd; continue }
            let units = aligned.map { (start: Double($0.startTime), end: Double($0.endTime), text: $0.text) }

            // Keep the trustworthy prefix: drop the saturated (crammed) tail, then drop past the
            // boundary margin — except on the final window, which keeps everything (nowhere to retry).
            let reliable = reliablePrefix(
                units, windowDur: windowDur, boundaryMargin: boundaryMargin,
                keepToEdge: isLast, trimSaturation: isLast == false
            )

            for u in reliable {
                results.append((u.start + audioStart, u.end + audioStart, u.text))
            }
            if isLast { break }

            // Advance text past the consumed units, matched by non-whitespace char count
            // (robust to tokenizer whitespace differences vs the input).
            let consumedNonWS = reliable.reduce(0) { acc, u in
                acc + u.text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
            }
            var dropped = 0
            var idx = remaining.startIndex
            while dropped < consumedNonWS && idx < remaining.endIndex {
                if remaining[idx].isWhitespace == false { dropped += 1 }
                idx = remaining.index(after: idx)
            }
            while idx < remaining.endIndex && remaining[idx].isWhitespace { idx = remaining.index(after: idx) }
            remaining = String(remaining[idx...])

            // Advance audio to the last reliable unit's end (≥5s progress so we can't stall).
            let lastEndAbs = (reliable.last?.end ?? windowDur) + audioStart
            audioStart = max(lastEndAbs, audioStart + 5.0)
        }
        return results
    }

    // Trims the leading instrumental intro on a vocal stem so the aligner doesn't pin the
    // first line to 0:00. Uses an ADAPTIVE energy gate, not a fixed amplitude: OpenUnmix
    // leaves low-level instrumental bleed in the "silent" intro that a fixed gate trips on
    // (observed on-device: trimmed 0.0s while the real vocal onset was seconds in, so line 1
    // pinned to 0:00). Instead we build a short-window RMS envelope and gate at a fraction
    // of the stem's OWN loud-vocal level (95th-percentile RMS, robust to transient clicks),
    // which self-calibrates to whatever the bleed floor happens to be. Returns the trimmed
    // audio and the lead removed in seconds (added back to timestamps afterward).
    private static func trimLeadingSilence(
        _ samples: [Float], sampleRate: Int, gateFraction: Float = 0.5, minRunMs: Int = 1000
    ) -> (trimmed: [Float], leadSec: Double) {
        guard samples.count > sampleRate / 5 else { return (samples, 0) }

        // 20 ms RMS envelope.
        let frameLen = max(1, sampleRate / 50)
        var env: [Float] = []
        env.reserveCapacity(samples.count / frameLen + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + frameLen, samples.count)
            var sum: Float = 0
            var j = i
            while j < end { sum += samples[j] * samples[j]; j += 1 }
            env.append((sum / Float(end - i)).squareRoot())
            i = end
        }

        // Smooth the envelope with a ~0.5 s centered moving average so brief faint blips
        // (breaths, a stray intro sound, isolation transients) don't read as onset — only
        // sustained singing survives the average. Without this the gate tripped on a
        // one-frame ~0.1 spike at 2 s while the real vocals start ~28 s.
        let half = max(1, (sampleRate / frameLen) / 4)   // ~0.25 s each side ≈ 0.5 s window
        var smooth = [Float](repeating: 0, count: env.count)
        for k in 0..<env.count {
            let lo = max(0, k - half), hi = min(env.count - 1, k + half)
            var s: Float = 0
            for m in lo...hi { s += env[m] }
            smooth[k] = s / Float(hi - lo + 1)
        }

        // Loud-vocal reference = 95th-percentile RMS; gate at a fraction of it. Faint intro
        // content sits below this fraction of the loud-vocal level; sung vocals sit above.
        let sorted = env.sorted()
        let ref = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        guard ref > 0 else { return (samples, 0) }
        let threshold = ref * gateFraction

        // First sustained run of the SMOOTHED envelope above the gate = vocal onset.
        let minRunFrames = max(1, minRunMs / 20)
        var run = 0
        var onsetFrame = -1
        for (k, e) in smooth.enumerated() {
            if e > threshold {
                run += 1
                if run >= minRunFrames { onsetFrame = k - run + 1; break }
            } else {
                run = 0
            }
        }
        breadcrumb(String(format: "trim: frames=%d ref95=%.4f gate=%.4f onsetFrame=%d",
                          env.count, ref, threshold, onsetFrame))
        // [DIAGNOSTIC] coarse energy profile (max RMS per 1 s) over the first 45 s, to see
        // where the real sustained vocal onset is vs. where the gate first trips.
        let fps = max(1, sampleRate / frameLen)
        var profile = ""
        for s in 0..<min(45, (env.count + fps - 1) / fps) {
            let lo = s * fps, hi = min((s + 1) * fps, env.count)
            if lo >= hi { break }
            var mx: Float = 0
            for k in lo..<hi { mx = max(mx, env[k]) }
            profile += String(format: "%d:%.3f ", s, mx)
        }
        breadcrumb("trim profile s:maxRMS " + profile)
        guard onsetFrame > 0 else { return (samples, 0) }
        // Schmitt-trigger backoff: the 50%-of-peak gate CONFIRMS sustained singing, but a word
        // that swells in only crosses 50% once it's underway — so the confirmed frame is late and
        // trimming there clips the first word's soft attack (segment-opening lines then align
        // ~1–2 s late). Walk the start edge back to where the smoothed envelope first rose above a
        // low floor (a fraction of the gate = the attack), bounded so a faint intro can't drag it
        // to 0. This keeps detection robust (high gate) while marking the onset early (low gate).
        let lowGate = threshold * 0.2
        let maxBackoff = max(1, fps * 3)
        var softOnset = onsetFrame
        while softOnset > 0, onsetFrame - softOnset < maxBackoff, smooth[softOnset - 1] > lowGate {
            softOnset -= 1
        }
        breadcrumb("trim onset frame \(onsetFrame)→\(softOnset) (soft-attack backoff)")
        let onset = softOnset * frameLen
        guard onset > sampleRate / 5 else { return (samples, 0) }   // <0.2s lead → not worth trimming
        let start = max(0, onset - sampleRate / 10)                 // keep 100 ms before onset
        return (Array(samples[start...]), Double(start) / Double(sampleRate))
    }

    // Previous fixed-amplitude gate (replaced — tripped on OpenUnmix bleed, never trimmed):
    // private static func trimLeadingSilence(
    //     _ samples: [Float], sampleRate: Int, threshold: Float = 0.02, minRunMs: Int = 120
    // ) -> (trimmed: [Float], leadSec: Double) {
    //     let minRun = max(1, sampleRate * minRunMs / 1000)
    //     var run = 0
    //     var onset = -1
    //     for i in 0..<samples.count {
    //         if abs(samples[i]) > threshold {
    //             run += 1
    //             if run >= minRun { onset = i - run + 1; break }
    //         } else {
    //             run = 0
    //         }
    //     }
    //     guard onset > sampleRate / 5 else { return (samples, 0) }
    //     let start = max(0, onset - sampleRate / 10)
    //     return (Array(samples[start...]), Double(start) / Double(sampleRate))
    // }

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
