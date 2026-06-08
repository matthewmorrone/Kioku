// ForcedAlignmentProvider.swift
// Orchestrates on-device forced alignment: decodes audio, tokenizes lyrics,
// runs Whisper with the logits filter callback to force the provided text,
// then extracts DTW-based per-token timestamps and maps them to lyric lines.

import AVFoundation
import whisper_cpp

// Runs forced alignment of lyric lines against an audio file using whisper.cpp.
// Creates a whisper context with DTW enabled via whisper_context_params so that
// per-token timestamps are computed from cross-attention weights. The logits
// filter callback forces the decoder to emit exactly the provided lyric tokens
// while Whisper handles timing via natural timestamp token insertion and DTW.
public final class ForcedAlignmentProvider {
    private let modelURL: URL

    // modelURL must point to a GGML .bin file.
    public init(modelURL: URL) {
        self.modelURL = modelURL
    }

    // Aligns the given lyric lines to the audio at audioURL.
    // Returns one AlignedLine per input line with timestamps in seconds,
    // plus ♪ cues for instrumental gaps above gapThreshold seconds.
    //
    // onProgress: called with 0–1 fraction as Whisper processes audio.
    // onSegment: called each time a Whisper segment completes with lines aligned so far.
    public func align(
        input: AlignmentInput,
        gapThreshold: Double = 1.5,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onSegment: (@Sendable ([AlignedLine]) -> Void)? = nil
    ) async throws -> AlignmentResult {
        guard input.lines.isEmpty == false else {
            throw NSError(
                domain: "SwiftWhisperAlign.ForcedAlignment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No lyric lines to align."]
            )
        }

        let frames = try await WhisperAudioFrameDecoder.decode(from: input.audioURL)
        guard frames.isEmpty == false else {
            throw NSError(
                domain: "SwiftWhisperAlign.ForcedAlignment",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Audio decoded to zero frames."]
            )
        }

        // Total audio duration in seconds (16 kHz sample rate).
        let audioDuration = Double(frames.count) / 16_000.0

        // Silence whisper.cpp / ggml stderr chatter (e.g. repeated
        // "ggml_gallocr_needs_realloc" during graph rebuilds). Installed once
        // per alignment call; whisper_log_set routes both whisper and ggml logs
        // through the same callback.
        Self.installSilentLogger()

        // Create whisper context with DTW enabled for accurate per-token timestamps.
        // DTW extracts timing from cross-attention weights, which is far more precise
        // than relying on timestamp tokens alone under forced alignment.
        let ctx = try makeContext()
        defer { whisper_free(ctx) }

        // Build the full forced-alignment state up front so we have the
        // complete tokenSequence and lineBoundaries to map back to lines.
        // The chunked driver below creates per-window states that hold just
        // the remaining slice of tokens.
        let fullState = try ForcedAlignmentState(lines: input.lines, ctx: ctx)

        // Drive forced alignment manually across 30 s audio windows.
        // whisper.cpp's internal chunking drops tokens at window boundaries
        // under forced alignment (decoder emits EOT before all lyrics are
        // consumed). Running whisper_full once per window with the remaining
        // tokens — and with no EOT allowed until every token of that window
        // has been forced — guarantees the decoder can't "end early".
        // Compute the non-speech interval list once up front; both the
        // chunked driver (for leading-silence skips) and the final line-
        // boundary pass (for silence suppression) consume it. Port of
        // stable-ts's nonspeech_predictor pipeline in the non-VAD path.
        //
        // The audio passed to NonSpeechDetector is band-passed to 200–
        // 5000 Hz so low-frequency bass and high-frequency cymbal energy
        // stop masking vocal silence (stable-ts's only_voice_freq=True).
        // The full-band `frames` array still feeds whisper.cpp inference
        // unchanged — band-limiting would degrade DTW accuracy.
        let vocalBandFrames = voiceFreqFilter(frames: frames)
        let nonSpeech = NonSpeechDetector(frames: vocalBandFrames)

        let globalTimestamps = try await runChunkedAlignment(
            ctx: ctx,
            frames: frames,
            fullTokens: fullState.tokenSequence,
            nonSpeech: nonSpeech,
            cancellationCheck: cancellationCheck,
            onProgress: onProgress
        )

        print("[ForcedAlign] model=\(modelURL.lastPathComponent) emitted=\(globalTimestamps.count) expected=\(fullState.tokenSequence.count) audio=\(String(format: "%.1f", audioDuration))s silences=\(nonSpeech.silentStarts.count)")

        // Extract per-token timestamps and map to lines.
        let lyricLines = extractAlignedLines(
            tokenTimestamps: globalTimestamps,
            lineBoundaries: fullState.lineBoundaries,
            inputLines: input.lines,
            frames: frames,
            nonSpeech: nonSpeech
        )
        // Surface the final aligned lines once (no mid-window partial results
        // under the chunked driver).
        onSegment?(lyricLines)

        // Insert ♪ cues for gaps where the audio is non-silent (music) — silent gaps are
        // skipped so we don't fill quiet stretches with spurious ♪ markers. The detector
        // built above is reused; no second decode and no separate type.
        let combined = AlignmentNonSpeechCueBuilder.insertNonSpeechCues(
            lyricLines: lyricLines,
            audioDuration: audioDuration,
            gapThreshold: gapThreshold,
            nonSpeech: nonSpeech
        )

        return AlignmentResult(lines: combined)
    }

    // Creates a whisper context with DTW per-token timestamps enabled, using the
    // model-specific alignment-heads preset. Shared by full-file alignment and the
    // single-line re-alignment path so both compute timing the same way. Caller owns
    // the returned context and must `whisper_free` it.
    private func makeContext() throws -> OpaquePointer {
        var cparams = whisper_context_default_params()
        cparams.dtw_token_timestamps = true
        cparams.dtw_aheads_preset = AlignmentTimestampMath.dtwPreset(for: modelURL)
        guard let ctx = modelURL.path.withCString({ path in
            whisper_init_from_file_with_params(path, cparams)
        }) else {
            throw NSError(
                domain: "SwiftWhisperAlign.ForcedAlignment",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load Whisper model from \(modelURL.lastPathComponent)."]
            )
        }
        return ctx
    }

    // Re-aligns a SINGLE lyric line against a bounded window of the audio, returning
    // both the line-level start/end and the per-token DTW timestamps mapped to the
    // line's character offsets. This is the engine behind the lyric view's "fix this
    // line's word sweep" control: the caller passes a padded window around the cue's
    // current [start,end] so the forced decoder only has to place this one line's
    // tokens within a few seconds of audio — far more reliable than re-running the
    // whole song, and fast enough to feel interactive.
    //
    // Unlike `align`, this keeps the per-token granularity instead of collapsing it
    // into one line span: the tokens become `CueCharTiming` checkpoints upstream.
    public func alignSingleLine(
        audioURL: URL,
        line: String,
        windowStartSeconds: Double,
        windowEndSeconds: Double,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AlignedLineTokens {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw NSError(
                domain: "SwiftWhisperAlign.ForcedAlignment",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Empty line — nothing to align."]
            )
        }

        let frames = try await WhisperAudioFrameDecoder.decode(from: audioURL)
        guard frames.isEmpty == false else {
            throw NSError(
                domain: "SwiftWhisperAlign.ForcedAlignment",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Audio decoded to zero frames."]
            )
        }

        // Slice the decoded frames to the requested window (clamped to the file).
        let sampleRate = 16_000
        let totalFrames = frames.count
        let startSample = max(0, min(totalFrames, Int(windowStartSeconds * Double(sampleRate))))
        let endSample = max(startSample, min(totalFrames, Int(windowEndSeconds * Double(sampleRate))))
        guard endSample > startSample else {
            throw NSError(
                domain: "SwiftWhisperAlign.ForcedAlignment",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Empty audio window for re-alignment."]
            )
        }
        let windowFrames = Array(frames[startSample..<endSample])
        let windowOffsetSeconds = Double(startSample) / Double(sampleRate)
        let windowEndClamped = Double(endSample) / Double(sampleRate)

        Self.installSilentLogger()

        let ctx = try makeContext()
        defer { whisper_free(ctx) }

        let state = try ForcedAlignmentState(lines: [trimmed], ctx: ctx)

        // Band-limit the slice for silence detection exactly as the full-file path does;
        // the unfiltered slice still feeds whisper inference.
        let vocalBandFrames = voiceFreqFilter(frames: windowFrames)
        let nonSpeech = NonSpeechDetector(frames: vocalBandFrames)

        let windowTimestamps = try await runChunkedAlignment(
            ctx: ctx,
            frames: windowFrames,
            fullTokens: state.tokenSequence,
            nonSpeech: nonSpeech,
            cancellationCheck: cancellationCheck,
            onProgress: onProgress
        )

        let tokens = buildAlignedTokens(
            ctx: ctx,
            line: trimmed,
            tokenSequence: state.tokenSequence,
            windowTimestamps: windowTimestamps,
            windowOffsetSeconds: windowOffsetSeconds
        )

        // Line-level bounds from the token spread, clamped inside the window. Used to
        // tighten the cue's own start/end so a fully-wrong line is fixed in one action.
        let lineStart = tokens.first?.start ?? windowOffsetSeconds
        let lastTokenStart = tokens.last?.start ?? lineStart
        let lineEnd = min(windowEndClamped, max(lastTokenStart + 0.3, lineStart + 0.3))
        let alignedLine = AlignedLine(text: trimmed, start: lineStart, end: lineEnd)

        return AlignedLineTokens(line: alignedLine, tokens: tokens)
    }

    // Decodes each line token back to its byte length and maps the running byte
    // boundary onto the line's UTF-16 offsets, yielding one karaoke checkpoint per
    // token. Token bytes are accumulated against a precomputed UTF-8→UTF-16 offset
    // table for the line (the tokens came from tokenizing this exact line, so their
    // concatenated bytes track the line's UTF-8 bytes; boundaries are clamped in case
    // BPE artifacts push past the end). Timestamps are offset back onto the original
    // audio timeline. Tokens past the committed-timestamp count (alignment ran short)
    // and zero-width tokens are dropped — neither can advance the highlight.
    private func buildAlignedTokens(
        ctx: OpaquePointer,
        line: String,
        tokenSequence: [whisper_token],
        windowTimestamps: [Double],
        windowOffsetSeconds: Double
    ) -> [AlignedToken] {
        let lineUTF8Count = line.utf8.count
        var byteToUTF16 = [Int](repeating: 0, count: lineUTF8Count + 1)
        var byteCursor = 0
        var utf16Cursor = 0
        for scalar in line.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            for k in 0..<scalarBytes where byteCursor + k <= lineUTF8Count {
                byteToUTF16[byteCursor + k] = utf16Cursor
            }
            byteCursor += scalarBytes
            utf16Cursor += String(scalar).utf16.count
        }
        byteToUTF16[lineUTF8Count] = utf16Cursor

        var tokens: [AlignedToken] = []
        var cumulativeBytes = 0
        let count = min(tokenSequence.count, windowTimestamps.count)
        for i in 0..<count {
            let tokenBytes: Int
            if let cString = whisper_token_to_str(ctx, tokenSequence[i]) {
                tokenBytes = strlen(cString)
            } else {
                tokenBytes = 0
            }
            let prevByte = min(cumulativeBytes, lineUTF8Count)
            cumulativeBytes += tokenBytes
            let nextByte = min(cumulativeBytes, lineUTF8Count)
            let charOffset = byteToUTF16[prevByte]
            let charLength = max(0, byteToUTF16[nextByte] - charOffset)
            guard charLength > 0 else { continue }
            tokens.append(AlignedToken(
                start: windowTimestamps[i] + windowOffsetSeconds,
                charOffsetUTF16: charOffset,
                charLengthUTF16: charLength
            ))
        }
        return tokens
    }

    // Reads DTW-based per-token timestamps (t_dtw) from the whisper context
    // and maps them back to lyric line boundaries. DTW timestamps come from
    // cross-attention weights and are far more accurate than decoder timestamp
    // tokens under forced alignment.
    //
    // Applies three post-processing passes that stable-ts does on the server
    // but whisper.cpp does not provide out of the box:
    //   1. Repair degenerate t_dtw values by interpolating from neighbors.
    //   2. Cap each line's trailing silence at pauseCapSeconds so a line's
    //      end does not get absorbed into the following silence when the
    //      next line's first token is far away.
    //   3. Clamp line edges to voiced audio via a small energy VAD so that
    //      leading/trailing silence is excluded from the caption window.
    private func extractAlignedLines(
        tokenTimestamps rawTimestamps: [Double],
        lineBoundaries: [Int],
        inputLines: [String],
        frames: [Float],
        nonSpeech: NonSpeechDetector
    ) -> [AlignedLine] {
        var tokenTimestamps = AlignmentTimestampMath.repairDegenerateTimestamps(rawTimestamps)

        // Build a VAD mask once; each line boundary queries it.
        let vad = VoiceActivityDetector(frames: frames)

        // Maximum trailing silence to attribute to a line before capping.
        // stable-ts uses ~160 ms; the same value keeps line ends close to the
        // last sung syllable rather than drifting into the next beat.
        let pauseCapSeconds = 0.16

        let lineCount = inputLines.count
        var lines: [AlignedLine] = []

        for i in 0..<lineCount {
            let startIdx = lineBoundaries[i]
            let endIdx = lineBoundaries[i + 1]

            guard startIdx < tokenTimestamps.count else {
                let fallbackStart = lines.last?.end ?? 0
                lines.append(AlignedLine(text: inputLines[i], start: fallbackStart, end: fallbackStart + 0.5))
                continue
            }

            let lastTokenIdx = min(endIdx - 1, tokenTimestamps.count - 1)
            let lineStartRaw = tokenTimestamps[startIdx]
            let lastTokenTs = tokenTimestamps[lastTokenIdx]

            // Pause-cap: candidate end is min(next-line start, last token + cap).
            let nextLineStart: Double? = (i + 1 < lineCount && lineBoundaries[i + 1] < tokenTimestamps.count)
                ? tokenTimestamps[lineBoundaries[i + 1]]
                : nil
            let cappedEnd: Double
            if let nextLineStart {
                cappedEnd = min(nextLineStart, lastTokenTs + pauseCapSeconds)
            } else {
                cappedEnd = lastTokenTs + pauseCapSeconds
            }

            // stable-ts suppress_silence (keep_end=True default): if a silent
            // interval straddles the line's start, push start forward to the
            // silence end. This is the authoritative pass.
            let (suppressedStart, suppressedEnd) = nonSpeech.suppressStartSilence(
                start: lineStartRaw,
                end: cappedEnd,
                minWordDur: 0.1
            )

            // Secondary fine clamp via the energy VAD — useful when the
            // NonSpeechDetector's 20 ms grid landed the boundary slightly
            // inside a silent frame. Bounded so it cannot move the boundary
            // more than 0.5 s past what suppress_silence already produced.
            let clampedStart = vad.clampForwardToVoiced(seconds: suppressedStart, maxSearch: 0.5)
            let clampedEnd = vad.clampBackwardToVoiced(seconds: suppressedEnd, maxSearch: 0.5)

            // Guarantee a visible minimum duration even after clamping.
            let lineStart = min(clampedStart, lastTokenTs)
            let lineEnd = max(clampedEnd, lineStart + 0.3)

            lines.append(AlignedLine(text: inputLines[i], start: lineStart, end: lineEnd))
        }

        _ = tokenTimestamps
        return lines
    }

    // Ports the core loop of stable-ts's Aligner.align(). For each 30 s audio
    // window we force a bounded batch (tokenStep) of the remaining lyric
    // tokens, examine the per-token durations that DTW produced, and commit
    // only the prefix of tokens whose durations look plausible. Any token
    // past the first implausible duration is returned to the queue and
    // retried in the next window with fresh audio context. The seek pointer
    // advances by exactly the end time of the last committed token — not by
    // a fixed window stride — which is how stable-ts survives chunk
    // boundaries without losing tokens.
    //
    // Reference: stable_whisper/non_whisper/alignment.py, Aligner.align() and
    // Aligner._fallback(). This port collapses stable-ts's per-word grouping
    // because for Japanese (split_words_by_space=False) each whisper token
    // is effectively its own word.
    private func runChunkedAlignment(
        ctx: OpaquePointer,
        frames: [Float],
        fullTokens: [whisper_token],
        nonSpeech: NonSpeechDetector,
        cancellationCheck: (@Sendable () -> Bool)?,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [Double] {
        let sampleRate = 16_000
        let windowSamples = 30 * sampleRate
        // Mirrors stable-ts's token_step=100 default. Longer batches
        // accumulate timing drift; shorter batches pay more inference calls
        // for little gain.
        let tokenStep = 100
        // stable-ts defaults: max 3 s per word, and locally at most 2 × the
        // median committed duration — whichever is tighter.
        let maxWordDurationGlobal: Double = 3.0
        let wordDurationFactor: Double = 2.0
        // stable-ts nonspeech_skip default: skip silent regions ≥ 5 s at
        // the head of a window rather than forcing tokens into silence.
        let nonspeechSkipSeconds: Double = 5.0

        let totalFrames = frames.count
        let totalTokens = fullTokens.count
        var committedTimestamps: [Double] = []
        committedTimestamps.reserveCapacity(totalTokens)
        var cursor = 0
        var audioStart = 0

        // Reused across iterations — language is constant.
        let langCString = strdup("ja")!
        defer { free(langCString) }

        // Hard safety net: the algorithm must make progress (either commit a
        // token or advance the audio by a full window). Nothing in theory can
        // stall it, but bugs in timing produce infinite loops instantly, so
        // we guard explicitly.
        var safetyIter = 0
        let maxIterations = max(64, totalTokens * 4 + Int(Double(totalFrames) / Double(windowSamples)) * 2)

        while audioStart < totalFrames && cursor < totalTokens && safetyIter < maxIterations {
            safetyIter += 1
            if cancellationCheck?() == true { throw CancellationError() }

            // Leading-silence skip (stable-ts _skip_nonspeech). If audioStart
            // falls inside a silent interval at least nonspeechSkipSeconds
            // long, jump to the end of that interval rather than forcing
            // tokens into music-only audio.
            let audioStartSeconds = Double(audioStart) / Double(sampleRate)
            let skipTo = nonSpeech.skipLeadingSilence(
                fromSeconds: audioStartSeconds,
                minSilence: nonspeechSkipSeconds
            )
            if skipTo > audioStartSeconds {
                let newStart = min(totalFrames, Int(skipTo * Double(sampleRate)))
                if newStart > audioStart {
                    audioStart = newStart
                    if audioStart >= totalFrames { break }
                }
            }

            let audioEnd = min(audioStart + windowSamples, totalFrames)
            let windowOffsetSeconds = Double(audioStart) / Double(sampleRate)
            let windowEndSeconds = Double(audioEnd) / Double(sampleRate)
            let windowFrames = Array(frames[audioStart..<audioEnd])

            // Batch: take up to tokenStep of the remaining tokens. The
            // callback suppresses EOT so the decoder emits exactly this batch
            // before stopping, keeping drift bounded within a batch.
            let batchSize = min(tokenStep, totalTokens - cursor)
            let windowSlice = Array(fullTokens[cursor..<(cursor + batchSize)])

            let windowState = ForcedAlignmentState(tokens: windowSlice, ctx: ctx)
            let unmanagedState = Unmanaged.passRetained(windowState)

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.language = UnsafePointer(langCString)
            params.token_timestamps = true
            params.print_progress = false
            params.print_realtime = false
            params.print_timestamps = false
            params.print_special = false
            params.logits_filter_callback = forcedAlignmentLogitsFilter
            params.logits_filter_callback_user_data = unmanagedState.toOpaque()

            let paramsForCall = params
            let result: Int32 = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = whisper_full(ctx, paramsForCall, windowFrames, Int32(windowFrames.count))
                    cont.resume(returning: r)
                }
            }
            unmanagedState.release()

            guard result == 0 else {
                throw NSError(
                    domain: "SwiftWhisperAlign.ForcedAlignment",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "whisper_full failed in window at \(String(format: "%.1f", windowOffsetSeconds))s (code \(result))"]
                )
            }

            // Collect this window's per-token t_dtw, offset to global time.
            let begToken = whisper_token_beg(ctx)
            let eotToken = whisper_token_eot(ctx)
            let segCount = whisper_full_n_segments(ctx)
            var windowTokenStarts: [Double] = []
            windowTokenStarts.reserveCapacity(batchSize)
            for seg in 0..<segCount {
                let tokCount = whisper_full_n_tokens(ctx, seg)
                for tok in 0..<tokCount {
                    let data = whisper_full_get_token_data(ctx, seg, tok)
                    if data.id >= begToken || data.id == eotToken { continue }
                    let globalTs = Double(data.t_dtw) * 0.01 + windowOffsetSeconds
                    windowTokenStarts.append(globalTs)
                }
            }

            // No tokens came out. Slide audio by a full window and retry the
            // same batch — matches stable-ts's nothing-aligned branch where
            // _seek_sample += segment_samples and nothing is committed.
            if windowTokenStarts.isEmpty {
                audioStart = audioEnd
                continue
            }

            // Per-token durations: dur[i] = t[i+1] - t[i], last = window_end - t[last].
            var durations: [Double] = []
            durations.reserveCapacity(windowTokenStarts.count)
            for i in 0..<windowTokenStarts.count {
                if i + 1 < windowTokenStarts.count {
                    durations.append(max(0, windowTokenStarts[i + 1] - windowTokenStarts[i]))
                } else {
                    durations.append(max(0, windowEndSeconds - windowTokenStarts[i]))
                }
            }

            // Indices of tokens with non-zero duration.
            var nonzeroIndices: [Int] = []
            for (i, d) in durations.enumerated() where d > 0 {
                nonzeroIndices.append(i)
            }

            // No word has any duration — treat as a failed window. Skip it.
            guard let lastNonzero = nonzeroIndices.last else {
                audioStart = audioEnd
                continue
            }

            // stable-ts _fallback: if the last non-zero token's end is pinned
            // to the window boundary (>= floor(window_end)), its duration is
            // "ran out of audio" rather than "natural word end" — drop it and
            // retry it next window.
            var lastGood = lastNonzero
            if nonzeroIndices.count > 1 {
                let lastEnd = (lastGood + 1 < windowTokenStarts.count)
                    ? windowTokenStarts[lastGood + 1]
                    : windowEndSeconds
                if lastEnd >= floor(windowEndSeconds) {
                    nonzeroIndices.removeLast()
                    lastGood = nonzeroIndices.last ?? lastGood
                }
            }
            var redoIndex = lastGood + 1

            // Local + global max-duration enforcement. A word whose duration
            // exceeds either is considered unreliable; everything from that
            // word onward goes back to the queue.
            let committedSoFar = Array(durations.prefix(redoIndex))
            let medDur = AlignmentTimestampMath.median(committedSoFar)
            let localMax = medDur.isFinite && medDur > 0 ? medDur * wordDurationFactor : maxWordDurationGlobal
            let effectiveMax = min(localMax, maxWordDurationGlobal)
            // Only check from the second non-zero onward (matches stable-ts
            // index_offset = first_nonzero + 1). The very first token
            // frequently has an inflated duration because of pre-song silence
            // and would otherwise always trip the cap.
            let firstNonzero = nonzeroIndices.first ?? 0
            if firstNonzero + 1 < redoIndex {
                for i in (firstNonzero + 1)..<redoIndex where durations[i] > effectiveMax {
                    redoIndex = i
                    break
                }
            }

            // Commit tokens [0..<redoIndex]; the rest re-enter the queue via
            // not advancing cursor past them.
            let commitCount = redoIndex
            if commitCount == 0 {
                audioStart = audioEnd
                continue
            }

            // Density guard: when the DTW attention can't find clear speech
            // anchors (e.g. instrumental intro with music energy in the voice
            // band), it crams tokens into a tiny time span — producing median
            // per-token durations well below what any real singing can produce
            // (~50 ms/mora at extreme speed). Detect this and skip the batch so
            // the tokens get retried against later audio that may contain vocals.
            if commitCount > 10 {
                let commitDurations = Array(durations.prefix(commitCount))
                let medDurCommit = AlignmentTimestampMath.median(commitDurations)
                if medDurCommit < 0.04 {
                    print("[ForcedAlign] skipping \(commitCount) tokens at \(String(format: "%.1f", windowOffsetSeconds))s: median duration \(String(format: "%.3f", medDurCommit))s (likely non-vocal audio)")
                    audioStart = audioEnd
                    continue
                }
            }

            for i in 0..<commitCount {
                committedTimestamps.append(windowTokenStarts[i])
            }
            cursor += commitCount

            // Advance audio to the end time of the last committed token.
            let lastCommittedEnd: Double
            if commitCount < windowTokenStarts.count {
                lastCommittedEnd = windowTokenStarts[commitCount]
            } else {
                lastCommittedEnd = windowTokenStarts[commitCount - 1] + durations[commitCount - 1]
            }
            let newAudioStart = Int(round(lastCommittedEnd * Double(sampleRate)))

            // Monotone guard: never rewind, always advance by at least a small
            // amount so the loop cannot stall.
            let minAdvance = sampleRate / 2   // 0.5 s
            audioStart = max(newAudioStart, audioStart + minAdvance)
            audioStart = min(audioStart, totalFrames)

            onProgress?(min(1.0, Double(cursor) / Double(totalTokens)))
        }

        return committedTimestamps
    }

    // Routes whisper.cpp + ggml log output to a no-op. Installed lazily on
    // the first alignment call so we don't silence logs globally until the
    // aligner actually runs. Stays on this class (not extracted to a namespace)
    // because the `loggerInstalled` static var can't move across files via an
    // extension without becoming public.
    private static var loggerInstalled = false
    private static func installSilentLogger() {
        guard loggerInstalled == false else { return }
        loggerInstalled = true
        whisper_log_set({ _, _, _ in }, nil)
    }
}

// Wraps a progress closure so it can be passed through C void* user_data.
private final class ProgressCallbackBox {
    let handler: (Double) -> Void
    init(handler: @escaping (Double) -> Void) { self.handler = handler }
}

// Wraps a cancellation check closure for the abort_callback.
private final class AbortCallbackBox {
    let shouldAbort: () -> Bool
    init(shouldAbort: @escaping () -> Bool) { self.shouldAbort = shouldAbort }
}

// Wraps the new_segment_callback state. Uses segment-level timing to
// interpolate line positions within each segment proportionally by token count.
private final class SegmentCallbackBox {
    let alignState: ForcedAlignmentState
    let inputLines: [String]
    let handler: ([AlignedLine]) -> Void
    // Running count of text tokens seen across all completed segments.
    var textTokensSeen: Int = 0
    var partialLines: [AlignedLine] = []

    init(alignState: ForcedAlignmentState, inputLines: [String], handler: @escaping ([AlignedLine]) -> Void) {
        self.alignState = alignState
        self.inputLines = inputLines
        self.handler = handler
    }

    // Called from the C callback when nNew segments have been decoded.
    // Uses segment t0/t1 to interpolate line timing proportionally.
    func handleNewSegments(ctx: OpaquePointer, nNew: Int32) {
        let begToken = whisper_token_beg(ctx)
        let eotToken = whisper_token_eot(ctx)
        let totalSegments = whisper_full_n_segments(ctx)
        let firstNew = totalSegments - nNew

        for seg in firstNew..<totalSegments {
            let segT0 = Double(whisper_full_get_segment_t0(ctx, seg)) * 0.01
            let segT1 = Double(whisper_full_get_segment_t1(ctx, seg)) * 0.01
            let tokenCount = whisper_full_n_tokens(ctx, seg)

            // Count text tokens in this segment.
            var segTextCount = 0
            for tok in 0..<tokenCount {
                let data = whisper_full_get_token_data(ctx, seg, tok)
                if data.id >= begToken || data.id == eotToken { continue }
                segTextCount += 1
            }

            guard segTextCount > 0 else { continue }

            // Use DTW timestamps (t_dtw) for each text token in this segment.
            var localIdx = 0
            for tok in 0..<tokenCount {
                let data = whisper_full_get_token_data(ctx, seg, tok)
                if data.id >= begToken || data.id == eotToken { continue }

                let ts = Double(data.t_dtw) * 0.01
                let globalIdx = textTokensSeen + localIdx

                // Check which line this token belongs to and update partialLines.
                let lineCount = inputLines.count
                for lineIdx in partialLines.count..<lineCount {
                    let lineStart = alignState.lineBoundaries[lineIdx]
                    let lineEnd = alignState.lineBoundaries[lineIdx + 1]

                    if globalIdx >= lineStart && globalIdx < lineEnd {
                        // First token of this line.
                        if lineIdx == partialLines.count {
                            partialLines.append(AlignedLine(
                                text: inputLines[lineIdx],
                                start: ts,
                                end: ts + 0.3
                            ))
                        }
                        break
                    } else if globalIdx >= lineEnd {
                        // Finalize previous line's end time.
                        if lineIdx < partialLines.count {
                            let existing = partialLines[lineIdx]
                            partialLines[lineIdx] = AlignedLine(
                                text: existing.text,
                                start: existing.start,
                                end: max(ts, existing.start + 0.3)
                            )
                        }
                        continue
                    } else {
                        break
                    }
                }

                // Extend the current line's end time.
                if let lastIdx = partialLines.indices.last {
                    let existing = partialLines[lastIdx]
                    partialLines[lastIdx] = AlignedLine(
                        text: existing.text,
                        start: existing.start,
                        end: max(ts + 0.3, existing.start + 0.3)
                    )
                }

                localIdx += 1
            }

            textTokensSeen += segTextCount
        }

        handler(partialLines)
    }
}
