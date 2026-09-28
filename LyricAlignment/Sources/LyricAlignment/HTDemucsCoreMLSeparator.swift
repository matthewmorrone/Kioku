// HTDemucsCoreMLSeparator.swift
// SOTA vocal isolation via HTDemucs-FT exported to CoreML (MIT, iOS 16, Neural Engine).
// The model (HTDemucsSpec) takes raw stereo [1,2,343980] @44.1kHz and returns the VOCALS
// spectrogram (complex-as-channels) + the vocals time-branch; this file does the cheap iSTFT
// overlap-add in Swift (coremltools can't convert it) and the 7.8s chunked overlap-add over a
// full song. The iSTFT matches torch.istft to float rounding (scripts/htdemucs-coreml).
import Foundation
import CoreML
import Accelerate
import os

private let logger = Logger(subsystem: "matthewmorrone.LyricAlignment", category: "HTDemucsCoreMLSeparator")

enum HTDemucsCoreMLSeparator {
    static let N = 4096, H = 1024, Fq = 2048
    static let log2N = 12
    static let SEG = 343_980          // model's fixed input length (7.8 s @ 44.1kHz)
    static let T = 336                 // spectrogram frames the model returns
    static let Tfull = 340             // frames after restoring the 2-frame crop each side
    static let cropOffset = N / 2 + (H / 2 * 3)   // center-pad (2048) + _spec pad (1536) = 3584

    // Periodic Hann window and the window-overlap normalization curve for the iSTFT (≈1.4 MB),
    // built once.
    private struct DSP { let win: [Float]; let wsum: [Float]; let outLen: Int }
    private static let dsp: DSP = {
        var win = [Float](repeating: 0, count: N)
        for n in 0..<N { win[n] = 0.5 - 0.5 * cosf(2.0 * Float.pi * Float(n) / Float(N)) }
        let outLen = (Tfull - 1) * H + N
        var wsum = [Float](repeating: 0, count: outLen)
        for t in 0..<Tfull { for n in 0..<N { wsum[t * H + n] += win[n] * win[n] } }
        return DSP(win: win, wsum: wsum, outLen: outLen)
    }()

    // ---- model loading via [[HTDemucsModelStore]]: first-run download + Application
    // Support cache, same purge-resistant placement as the ASR + CTC aligner weights.
    // NOT cached in memory: a 269 MB MLModel left resident OOM-kills the aligner that
    // runs right after, so we build → predict → drop on every isolation. ----
    static func loadModel(onStage: (@Sendable (String) -> Void)? = nil) async throws -> MLModel {
        let url = try await HTDemucsModelStore.ensureModel(onStage: onStage)
        let cfg = MLModelConfiguration()
        // .all, not .cpuOnly: GPU/ANE is faster and more power-efficient than the CPU. On iOS 27
        // beta 24A5380h this model's attention layers crashed CoreML's GPU/ANE compilation inside
        // Apple's MetalPerformanceShadersGraph MLIR optimizer (FoldMultiplyIntoSDPAScale), which
        // forced .cpuOnly for a while (commit 6494aab); later betas compile it fine. If that crash
        // reappears on a new OS build, fall back to .cpuOnly.
        cfg.computeUnits = .all
        return try MLModel(contentsOf: url, configuration: cfg)
    }

    // Isolates vocals from decoded stereo, returning full-length mono vocals at 44.1 kHz.
    // The await is at the top (model-store check + any first-run download); the iSTFT
    // overlap-add loop below runs synchronously on the caller's task.
    // `waitUntilReady`, when supplied, is awaited before every chunk. iOS refuses GPU work from a
    // backgrounded process and aborts the command buffer, so a host that knows it has gone to the
    // background parks the loop here instead of letting the next `predict` fail. The accumulators
    // hold their partial result across the wait, and a suspended process resumes mid-loop.
    static func isolateVocalsMono(
        stereo: [[Float]],
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        waitUntilReady: (@Sendable () async -> Void)? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onStage: (@Sendable (String) -> Void)? = nil
    ) async throws -> [Float] {
        guard stereo.count == 2 else { return [] }
        let L = min(stereo[0].count, stereo[1].count)
        guard L > 0 else { return [] }
        let model = try await loadModel(onStage: onStage)
        guard let fft = vDSP_create_fftsetup(vDSP_Length(log2N), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fft) }
        // Where the time goes, logged once at the end: the model call vs our iSTFT/overlap-add.
        var predictSeconds = 0.0
        var postSeconds = 0.0
        let started = Date()

        // 7.8 s chunks, 10% overlap, triangular transition weight (demucs apply_model style).
        // 10% rather than demucs' default 25% processes ~17% less audio; the triangle weights
        // are renormalized per sample, so the seams blend the same way over a shorter span.
        let overlap = SEG / 10
        let stride = SEG - overlap
        let triangle = transitionWeight(SEG)

        var acc = [Float](repeating: 0, count: L)
        var wacc = [Float](repeating: 0, count: L)
        var start = 0
        // Attempts spent on the chunk at `start`; reset each time one lands.
        var chunkAttempts = 0
        while start < L {
            // Throws (not `break`): acc/wacc are pre-sized to the FULL song length but only filled
            // as chunks complete, so a `break` before the first chunk finishes returns an all-zero
            // array of the correct length. That passes the caller's `isEmpty` guard and gets cached
            // by VocalStemCache as if it were a real isolation — poisoning every future Re-align of
            // that song with a permanently silent stem, and the cache never invalidates it since
            // "isEmpty" is never true (seen 2026-09-22, commit 6717695). Throwing means a cancelled
            // isolation is never mistaken for a completed one.
            if cancellationCheck?() == true { throw CancellationError() }
            await waitUntilReady?()
            if cancellationCheck?() == true { throw CancellationError() }
            let end = min(L, start + SEG)
            let n = end - start
            // Per-chunk autoreleasepool drain: predict() returns MLMultiArray-backed values
            // that sit in the calling thread's autorelease pool until the next run-loop tick.
            // This loop has no tick — without an explicit drain, ~45 chunks × ~30 MB of
            // transient CoreML buffers pile up (≈1.4 GB) and cross jetsam on longer songs.
            // The accumulators (acc, wacc) live outside the pool, so per-chunk results
            // survive; only the transient buffers (lch/rch, MLMultiArrays, freqL/R) drain.
            do {
            try autoreleasepool {
                // Pad the chunk to SEG (the model is fixed-length).
                var lch = [Float](repeating: 0, count: SEG)
                var rch = [Float](repeating: 0, count: SEG)
                for i in 0..<n { lch[i] = stereo[0][start + i]; rch[i] = stereo[1][start + i] }

                let predictStart = Date()
                let (specL, specR, timeL, timeR) = try predict(model: model, left: lch, right: rch)
                let postStart = Date()
                predictSeconds += postStart.timeIntervalSince(predictStart)
                // Vocals = iSTFT(spec) + time-branch, per channel; downmix to mono.
                let freqL = istftChannel(re: specL.re, im: specL.im, fft: fft)
                let freqR = istftChannel(re: specR.re, im: specR.im, fft: fft)
                // Overlap-add (triangular) into the accumulator.
                for i in 0..<n {
                    let w = triangle[i]
                    let v = ((freqL[i] + timeL[i]) + (freqR[i] + timeR[i])) * 0.5
                    acc[start + i] += v * w
                    wacc[start + i] += w
                }
                // Fraction of audio processed (not chunk index) so the phase reaches a true 100%
                // on the final chunk — chunk-count estimates over-shoot and stall the bar at ~97%.
                onProgress?(Double(end) / Double(L))
                postSeconds += Date().timeIntervalSince(postStart)
            }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The prediction in flight when the app leaves the foreground is aborted by iOS.
                // Nothing reaches the accumulators until predict returns, so this chunk can simply
                // be run again — back round the loop, where waitUntilReady parks until it can.
                // The attempt cap keeps a genuinely broken prediction from looping forever.
                chunkAttempts += 1
                if chunkAttempts >= 3 { throw error }
                continue
            }
            chunkAttempts = 0
            if end >= L { break }
            start += stride
        }
        var out = [Float](repeating: 0, count: L)
        for i in 0..<L { out[i] = wacc[i] > 1e-6 ? acc[i] / wacc[i] : 0 }
        let total = Date().timeIntervalSince(started)
        logger.info("isolated \(Double(L) / 44_100, format: .fixed(precision: 1)) s of audio in \(total, format: .fixed(precision: 1)) s: model \(predictSeconds, format: .fixed(precision: 1)) s, iSTFT+overlap-add \(postSeconds, format: .fixed(precision: 1)) s")
        return out
    }

    // Triangular window (ramp up to middle, down to edges), normalized to max 1.
    private static func transitionWeight(_ len: Int) -> [Float] {
        var w = [Float](repeating: 0, count: len)
        let half = len / 2
        for i in 0..<half { w[i] = Float(i + 1) }
        for i in half..<len { w[i] = Float(len - i) }
        let m = w.max() ?? 1
        return w.map { $0 / m }
    }

    // ---- one model prediction: stereo SEG -> per-channel (spec re/im, time) ----
    private struct Spec { let re: [Float]; let im: [Float] }   // each [Fq * T] row-major (k major, t minor)
    private static func predict(model: MLModel, left: [Float], right: [Float])
        throws -> (Spec, Spec, [Float], [Float]) {
        let mix = try MLMultiArray(shape: [1, 2, NSNumber(value: SEG)], dataType: .float32)
        let mp = mix.dataPointer.bindMemory(to: Float.self, capacity: 2 * SEG)
        left.withUnsafeBufferPointer { mp.update(from: $0.baseAddress!, count: SEG) }
        right.withUnsafeBufferPointer { (mp + SEG).update(from: $0.baseAddress!, count: SEG) }

        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mix": mix]))
        guard let spec = out.featureValue(for: "vocals_spec")?.multiArrayValue,   // [1,4,Fq,T]
              let time = out.featureValue(for: "vocals_time")?.multiArrayValue     // [1,2,SEG]
        else {
            throw NSError(domain: "LyricAlignment.HTDemucs", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Model output missing."])
        }
        let sp = spec.dataPointer.bindMemory(to: Float.self, capacity: 4 * Fq * T)
        let tp = time.dataPointer.bindMemory(to: Float.self, capacity: 2 * SEG)
        // spec channel order: [L_re, L_im, R_re, R_im], each Fq*T row-major.
        func plane(_ ch: Int) -> [Float] {
            let base = ch * Fq * T
            return Array(UnsafeBufferPointer(start: sp + base, count: Fq * T))
        }
        let specL = Spec(re: plane(0), im: plane(1))
        let specR = Spec(re: plane(2), im: plane(3))
        let timeL = Array(UnsafeBufferPointer(start: tp, count: SEG))
        let timeR = Array(UnsafeBufferPointer(start: tp + SEG, count: SEG))
        return (specL, specR, timeL, timeR)
    }

    // iSTFT for one channel: re/im [Fq * T] (k major) -> SEG samples. Each frame is an inverse
    // real FFT scaled like torch.istft(normalized=True) — √N · irfft — then windowed and
    // overlap-added. The model drops the Nyquist bin and the 2 edge frames each side; those are
    // zero, so the edge frames contribute nothing and are skipped.
    private static func istftChannel(re: [Float], im: [Float], fft: FFTSetup) -> [Float] {
        let half = N / 2
        // vDSP's inverse real FFT of a true spectrum returns N · x; √N · x is what torch gives.
        let scale = Float(N).squareRoot() / Float(N)
        var out = [Float](repeating: 0, count: dsp.outLen)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: N)
        for t in 0..<T {
            // Bins 0..<N/2 fill the packed format directly; imagp[0] holds the (zero) Nyquist bin,
            // and the DC bin's imaginary part is ignored, as irfft ignores it.
            for k in 0..<half {
                realp[k] = re[k * T + t]
                imagp[k] = im[k * T + t]
            }
            imagp[0] = 0
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(fft, &split, 1, vDSP_Length(log2N), FFTDirection(FFT_INVERSE))
                    frame.withUnsafeMutableBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                        }
                    }
                }
            }
            // Window + overlap-add at this frame's slot in the uncropped [Tfull] timeline.
            let ob = (t + 2) * H
            for n in 0..<N { out[ob + n] += frame[n] * scale * dsp.win[n] }
        }
        for i in 0..<dsp.outLen { out[i] = dsp.wsum[i] > 1e-8 ? out[i] / dsp.wsum[i] : 0 }
        // Crop to SEG samples starting at the center+_spec pad offset.
        return Array(out[cropOffset ..< cropOffset + SEG])
    }
}
