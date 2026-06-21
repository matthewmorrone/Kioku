// HTDemucsCoreMLSeparator.swift
// SOTA vocal isolation via HTDemucs-FT exported to CoreML (MIT, iOS 16, Neural Engine).
// The model (HTDemucsSpec) takes raw stereo [1,2,343980] @44.1kHz and returns the VOCALS
// spectrogram (complex-as-channels) + the vocals time-branch; this file does the cheap iSTFT
// overlap-add in Swift (coremltools can't convert it) and the 7.8s chunked overlap-add over a
// full song. All STFT/iSTFT math is bit-exact vs torch (verified: scripts/htdemucs-coreml).
import Foundation
import CoreML
import Accelerate

enum HTDemucsCoreMLSeparator {
    static let N = 4096, H = 1024, K = 2049, Fq = 2048
    static let SEG = 343_980          // model's fixed input length (7.8 s @ 44.1kHz)
    static let T = 336                 // spectrogram frames the model returns
    static let Tfull = 340             // frames after restoring the 2-frame crop each side
    static let cropOffset = N / 2 + (H / 2 * 3)   // center-pad (2048) + _spec pad (1536) = 3584

    // Inverse-DFT basis [K x N] row-major, periodic Hann window, and the window-overlap
    // normalization curve. Built per-isolation and dropped on return (≈67 MB) so it isn't
    // resident competing with the aligner's MLX allocations.
    private struct DSP { let icos: [Float]; let isin: [Float]; let win: [Float]; let wsum: [Float]; let outLen: Int }
    private static func buildDSP() -> DSP {
        var icos = [Float](repeating: 0, count: K * N)
        var isin = [Float](repeating: 0, count: K * N)
        let sN = Float(N).squareRoot()
        for k in 0..<K {
            let c: Float = (k == 0 || k == N / 2) ? 1.0 : 2.0
            let scale = c / Float(N) * sN
            let twoPiK = 2.0 * Float.pi * Float(k) / Float(N)
            for n in 0..<N {
                let ang = twoPiK * Float(n)
                icos[k * N + n] = scale * cosf(ang)
                isin[k * N + n] = -scale * sinf(ang)
            }
        }
        var win = [Float](repeating: 0, count: N)
        for n in 0..<N { win[n] = 0.5 - 0.5 * cosf(2.0 * Float.pi * Float(n) / Float(N)) }
        let outLen = (Tfull - 1) * H + N
        var wsum = [Float](repeating: 0, count: outLen)
        for t in 0..<Tfull { for n in 0..<N { wsum[t * H + n] += win[n] * win[n] } }
        return DSP(icos: icos, isin: isin, win: win, wsum: wsum, outLen: outLen)
    }

    // ---- model loading (dev: from <Documents>/HTDemucsSpec.mlmodelc; later: bundle/download).
    // NOT cached: a 269 MB MLModel left resident OOM-kills the aligner that runs right after. ----
    static func loadModel() throws -> MLModel {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("HTDemucsSpec.mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "SwiftWhisperAlign.HTDemucs", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "HTDemucs model not found at \(url.lastPathComponent)."])
        }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .all
        return try MLModel(contentsOf: url, configuration: cfg)
    }

    // Isolates vocals from decoded stereo, returning full-length mono vocals at 44.1 kHz.
    static func isolateVocalsMono(
        stereo: [[Float]],
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [Float] {
        guard stereo.count == 2 else { return [] }
        let L = min(stereo[0].count, stereo[1].count)
        guard L > 0 else { return [] }
        let model = try loadModel()
        let dsp = buildDSP()

        // 7.8 s chunks, 25% overlap, triangular transition weight (demucs apply_model style).
        let overlap = SEG / 4
        let stride = SEG - overlap
        let triangle = transitionWeight(SEG)

        var acc = [Float](repeating: 0, count: L)
        var wacc = [Float](repeating: 0, count: L)
        var start = 0
        while start < L {
            if cancellationCheck?() == true { break }
            let end = min(L, start + SEG)
            let n = end - start
            // Pad the chunk to SEG (the model is fixed-length).
            var lch = [Float](repeating: 0, count: SEG)
            var rch = [Float](repeating: 0, count: SEG)
            for i in 0..<n { lch[i] = stereo[0][start + i]; rch[i] = stereo[1][start + i] }

            let (specL, specR, timeL, timeR) = try predict(model: model, left: lch, right: rch)
            // Vocals = iSTFT(spec) + time-branch, per channel; downmix to mono.
            let freqL = istftChannel(re: specL.re, im: specL.im, dsp: dsp)
            let freqR = istftChannel(re: specR.re, im: specR.im, dsp: dsp)
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
            if end >= L { break }
            start += stride
        }
        var out = [Float](repeating: 0, count: L)
        for i in 0..<L { out[i] = wacc[i] > 1e-6 ? acc[i] / wacc[i] : 0 }
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
            throw NSError(domain: "SwiftWhisperAlign.HTDemucs", code: 2,
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

    // iSTFT for one channel: re/im [Fq * T] (k major) -> SEG samples.
    private static func istftChannel(re: [Float], im: [Float], dsp: DSP) -> [Float] {
        // Restore to [Tfull x K]: bin K-1 (Nyquist) = 0; frames 0,1 and Tfull-2,Tfull-1 = 0.
        var reFull = [Float](repeating: 0, count: Tfull * K)
        var imFull = [Float](repeating: 0, count: Tfull * K)
        for t in 0..<T {
            let dst = (t + 2) * K
            for k in 0..<Fq {
                reFull[dst + k] = re[k * T + t]
                imFull[dst + k] = im[k * T + t]
            }
        }
        // Y[Tfull x N] = reFull[Tfull x K] @ icos[K x N] + imFull[Tfull x K] @ isin[K x N].
        var y = [Float](repeating: 0, count: Tfull * N)
        dsp.icos.withUnsafeBufferPointer { ic in
            reFull.withUnsafeBufferPointer { rf in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                            Int32(Tfull), Int32(N), Int32(K), 1.0,
                            rf.baseAddress, Int32(K), ic.baseAddress, Int32(N), 0.0, &y, Int32(N))
            }
        }
        dsp.isin.withUnsafeBufferPointer { isb in
            imFull.withUnsafeBufferPointer { iff in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                            Int32(Tfull), Int32(N), Int32(K), 1.0,
                            iff.baseAddress, Int32(K), isb.baseAddress, Int32(N), 1.0, &y, Int32(N))
            }
        }
        // Window each frame + overlap-add + normalize.
        var out = [Float](repeating: 0, count: dsp.outLen)
        for t in 0..<Tfull {
            let yb = t * N, ob = t * H
            for n in 0..<N { out[ob + n] += y[yb + n] * dsp.win[n] }
        }
        for i in 0..<dsp.outLen { out[i] = dsp.wsum[i] > 1e-8 ? out[i] / dsp.wsum[i] : 0 }
        // Crop to SEG samples starting at the center+_spec pad offset.
        return Array(out[cropOffset ..< cropOffset + SEG])
    }
}
