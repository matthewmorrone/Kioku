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
        cancellationCheck: (() -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onSegment: (([AlignedLine]) -> Void)? = nil
    ) async throws -> AlignmentResult {
        guard input.lines.isEmpty == false else {
            throw NSError(
                domain: "WhisperKitAlign.ForcedAlignment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No lyric lines to align."]
            )
        }

        let frames = try await decodeAudioFrames(from: input.audioURL)
        guard frames.isEmpty == false else {
            throw NSError(
                domain: "WhisperKitAlign.ForcedAlignment",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Audio decoded to zero frames."]
            )
        }

        // Total audio duration in seconds (16 kHz sample rate).
        let audioDuration = Double(frames.count) / 16_000.0

        // Create whisper context with DTW enabled for accurate per-token timestamps.
        // DTW extracts timing from cross-attention weights, which is far more precise
        // than relying on timestamp tokens alone under forced alignment.
        var cparams = whisper_context_default_params()
        cparams.dtw_token_timestamps = true
        cparams.dtw_aheads_preset = dtwPreset(for: modelURL)

        guard let ctx = modelURL.path.withCString({ path in
            whisper_init_from_file_with_params(path, cparams)
        }) else {
            throw NSError(
                domain: "WhisperKitAlign.ForcedAlignment",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load Whisper model from \(modelURL.lastPathComponent)."]
            )
        }
        defer { whisper_free(ctx) }

        // Build the forced alignment state (tokenizes each line).
        let alignState = try ForcedAlignmentState(lines: input.lines, ctx: ctx)
        let unmanagedState = Unmanaged.passRetained(alignState)
        defer { unmanagedState.release() }

        // Configure full params for forced alignment.
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        // Set language to Japanese.
        let langCString = strdup("ja")!
        defer { free(langCString) }
        params.language = UnsafePointer(langCString)

        // Enable token-level timestamps (used alongside DTW).
        params.token_timestamps = true

        // Attach the logits filter callback to force lyric tokens.
        params.logits_filter_callback = forcedAlignmentLogitsFilter
        params.logits_filter_callback_user_data = unmanagedState.toOpaque()

        // Wire up progress via a boxed closure passed through user_data.
        var progressBox: ProgressCallbackBox?
        if let onProgress {
            let box = ProgressCallbackBox(handler: onProgress)
            progressBox = box
            let unmanagedBox = Unmanaged.passRetained(box)
            params.progress_callback_user_data = unmanagedBox.toOpaque()
            params.progress_callback = { _, _, progress, userData in
                guard let userData else { return }
                let box = Unmanaged<ProgressCallbackBox>.fromOpaque(userData).takeUnretainedValue()
                box.handler(Double(progress) / 100.0)
            }
        }
        defer {
            if let ptr = params.progress_callback_user_data {
                Unmanaged<ProgressCallbackBox>.fromOpaque(ptr).release()
            }
        }

        // Wire up new_segment_callback to report partial alignment results.
        var segmentBox: SegmentCallbackBox?
        if let onSegment {
            let box = SegmentCallbackBox(
                alignState: alignState,
                inputLines: input.lines,
                handler: onSegment
            )
            segmentBox = box
            let unmanagedBox = Unmanaged.passRetained(box)
            params.new_segment_callback_user_data = unmanagedBox.toOpaque()
            params.new_segment_callback = { ctx, _, nNew, userData in
                guard let ctx, let userData, nNew > 0 else { return }
                let box = Unmanaged<SegmentCallbackBox>.fromOpaque(userData).takeUnretainedValue()
                box.handleNewSegments(ctx: ctx, nNew: nNew)
            }
        }
        defer {
            if let ptr = params.new_segment_callback_user_data {
                Unmanaged<SegmentCallbackBox>.fromOpaque(ptr).release()
            }
        }

        // Wire up abort callback so the caller can cancel mid-inference.
        var abortBox: AbortCallbackBox?
        if let cancellationCheck {
            let box = AbortCallbackBox(shouldAbort: cancellationCheck)
            abortBox = box
            let unmanagedBox = Unmanaged.passRetained(box)
            params.abort_callback_user_data = unmanagedBox.toOpaque()
            params.abort_callback = { userData in
                guard let userData else { return false }
                let box = Unmanaged<AbortCallbackBox>.fromOpaque(userData).takeUnretainedValue()
                return box.shouldAbort()
            }
        }
        defer {
            if let ptr = params.abort_callback_user_data {
                Unmanaged<AbortCallbackBox>.fromOpaque(ptr).release()
            }
        }

        // Run inference on a background thread. whisper_full is synchronous.
        let wasCancelled = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = whisper_full(ctx, params, frames, Int32(frames.count))
                if result != 0 {
                    // Check if this was a cancellation (abort_callback returned true).
                    if cancellationCheck?() == true {
                        cont.resume(returning: true)
                    } else {
                        cont.resume(throwing: NSError(
                            domain: "WhisperKitAlign.ForcedAlignment",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "whisper_full failed with code \(result)."]
                        ))
                    }
                } else {
                    cont.resume(returning: false)
                }
            }
        }
        _ = abortBox

        if wasCancelled {
            throw CancellationError()
        }
        // Prevent premature deallocation of callback boxes.
        _ = progressBox
        _ = segmentBox

        // Extract per-token timestamps and map to lines.
        let lyricLines = extractAlignedLines(
            ctx: ctx,
            state: alignState,
            inputLines: input.lines
        )

        // Insert ♪ cues for instrumental gaps.
        let combined = insertNonSpeechCues(
            lyricLines: lyricLines,
            audioDuration: audioDuration,
            gapThreshold: gapThreshold
        )

        return AlignmentResult(lines: combined)
    }

    // Reads DTW-based per-token timestamps (t_dtw) from the whisper context
    // and maps them back to lyric line boundaries. DTW timestamps come from
    // cross-attention weights and are far more accurate than decoder timestamp
    // tokens under forced alignment.
    private func extractAlignedLines(
        ctx: OpaquePointer,
        state: ForcedAlignmentState,
        inputLines: [String]
    ) -> [AlignedLine] {
        let begToken = whisper_token_beg(ctx)
        let eotToken = whisper_token_eot(ctx)
        let segmentCount = whisper_full_n_segments(ctx)

        // Collect DTW timestamps for all text tokens across all segments.
        var tokenTimestamps: [Double] = []

        for seg in 0..<segmentCount {
            let tokenCount = whisper_full_n_tokens(ctx, seg)
            for tok in 0..<tokenCount {
                let data = whisper_full_get_token_data(ctx, seg, tok)
                if data.id >= begToken || data.id == eotToken { continue }
                // t_dtw is in centiseconds (10ms units).
                let ts = Double(data.t_dtw) * 0.01
                tokenTimestamps.append(ts)
            }
        }

        // Map token timestamps to line boundaries.
        let lineCount = inputLines.count
        var lines: [AlignedLine] = []

        for i in 0..<lineCount {
            let startIdx = state.lineBoundaries[i]
            let endIdx = state.lineBoundaries[i + 1]

            guard startIdx < tokenTimestamps.count else {
                let fallbackStart = lines.last?.end ?? 0
                lines.append(AlignedLine(text: inputLines[i], start: fallbackStart, end: fallbackStart + 0.5))
                continue
            }

            let lineStart = tokenTimestamps[startIdx]

            let lineEnd: Double
            if i + 1 < lineCount && state.lineBoundaries[i + 1] < tokenTimestamps.count {
                lineEnd = tokenTimestamps[state.lineBoundaries[i + 1]]
            } else {
                let lastTokenIdx = min(endIdx - 1, tokenTimestamps.count - 1)
                lineEnd = tokenTimestamps[lastTokenIdx] + 0.5
            }

            lines.append(AlignedLine(
                text: inputLines[i],
                start: lineStart,
                end: max(lineEnd, lineStart + 0.3)
            ))
        }

        return lines
    }

    // Returns the DTW alignment heads preset for the given model file.
    private static func dtwPreset(for modelURL: URL) -> whisper_alignment_heads_preset {
        let name = modelURL.deletingPathExtension().lastPathComponent.lowercased()
        if name.contains("tiny.en") { return WHISPER_AHEADS_TINY_EN }
        if name.contains("tiny")    { return WHISPER_AHEADS_TINY }
        if name.contains("base.en") { return WHISPER_AHEADS_BASE_EN }
        if name.contains("base")    { return WHISPER_AHEADS_BASE }
        if name.contains("small.en") { return WHISPER_AHEADS_SMALL_EN }
        if name.contains("small")   { return WHISPER_AHEADS_SMALL }
        if name.contains("medium.en") { return WHISPER_AHEADS_MEDIUM_EN }
        if name.contains("medium")  { return WHISPER_AHEADS_MEDIUM }
        if name.contains("large-v3") { return WHISPER_AHEADS_LARGE_V3 }
        if name.contains("large-v2") { return WHISPER_AHEADS_LARGE_V2 }
        if name.contains("large-v1") || name.contains("large") { return WHISPER_AHEADS_LARGE_V1 }
        // Fallback: use top-most layers which works for any model.
        return WHISPER_AHEADS_N_TOP_MOST
    }

    // Instance method wrapper for the static preset lookup.
    private func dtwPreset(for modelURL: URL) -> whisper_alignment_heads_preset {
        Self.dtwPreset(for: modelURL)
    }

    // Inserts ♪ cues for gaps between lyric lines that exceed the threshold.
    private func insertNonSpeechCues(
        lyricLines: [AlignedLine],
        audioDuration: Double,
        gapThreshold: Double
    ) -> [AlignedLine] {
        var combined: [AlignedLine] = []

        // Gap before first lyric line.
        if let first = lyricLines.first, first.start > gapThreshold {
            combined.append(AlignedLine(text: "♪", start: 0, end: first.start))
        }

        for (i, line) in lyricLines.enumerated() {
            combined.append(line)

            // Gap between consecutive lines.
            if i + 1 < lyricLines.count {
                let gap = lyricLines[i + 1].start - line.end
                if gap > gapThreshold {
                    combined.append(AlignedLine(text: "♪", start: line.end, end: lyricLines[i + 1].start))
                }
            }
        }

        // Gap after last lyric line.
        if let last = lyricLines.last, audioDuration - last.end > gapThreshold {
            combined.append(AlignedLine(text: "♪", start: last.end, end: audioDuration))
        }

        return combined
    }

    // Decodes audio to 16 kHz mono 32-bit float PCM — the format whisper.cpp requires.
    private func decodeAudioFrames(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(
                domain: "WhisperKitAlign.ForcedAlignment",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "No audio track found in file."]
            )
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey:              kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey:      true,
            AVLinearPCMBitDepthKey:     32,
            AVLinearPCMIsBigEndianKey:  false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey:            16_000,
            AVNumberOfChannelsKey:      1
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw NSError(
                domain: "WhisperKitAlign.ForcedAlignment",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Could not configure audio reader."]
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "WhisperKitAlign.ForcedAlignment",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Audio reader failed to start."]
            )
        }

        var frames: [Float] = []

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var dataLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &dataLength,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer, dataLength > 0 else { continue }

            let sampleCount = dataLength / MemoryLayout<Float>.size
            let floatPointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            frames.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: sampleCount))
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "WhisperKitAlign.ForcedAlignment",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Audio reader failed while decoding."]
            )
        }

        return frames
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
