// MMSEmissions.swift
//
// Runs the CoreML MMS forced aligner (wav2vec2 + CTC head) over a 16 kHz mono signal in
// fixed 32 s windows and stitches the per-frame log-probabilities into one matrix for the
// whole signal. The export has a fixed input shape, so the signal is cut into overlapping
// windows and each window's interior frames are kept — the 2 s of context on either side is
// there only so a frame never sits at a window edge.

import AVFoundation
import CoreML
import Foundation

enum MMSEmissions {
    static let sampleRate = 16_000
    static let windowSec = 32.0
    static let windowSamples = 512_000
    static let overlapSec = 2.0
    // Output alphabet of the export: blank, then MMS's uroman letters, then the star token.
    static let labels: [Character] = ["-", "a", "i", "e", "n", "o", "u", "t", "s", "r", "m", "k", "l", "d", "g", "h", "y", "b", "p", "w", "c", "v", "j", "z", "f", "'", "q", "x", "*"]
    static let classes = 29
    static let blank = 0

    struct Matrix {
        let frames: Int
        let frameSec: Double
        var values: [Float]   // row-major [frames × classes]
    }

    static func loadModel(onStage: (@Sendable (String) -> Void)? = nil) async throws -> MLModel {
        let url = try await MMSModelStore.ensureModel(onStage: onStage)
        let cfg = MLModelConfiguration()
        // CPU only, deliberately. Measured on an iPhone 17 for a 260 s song: `.all` loads in
        // 11 s, holds ~1.1 GB and writes ~1 GB of compile cache on first use for a 5 s emission
        // pass; CPU loads in 1 s with ~100 MB and takes 9 s — identical output, faster overall,
        // and no memory cliff next to the isolator. `.cpuAndNeuralEngine` differs numerically
        // enough to park one line 13 s off.
        cfg.computeUnits = .cpuOnly
        return try MLModel(contentsOf: url, configuration: cfg)
    }

    // 44.1 kHz mono → 16 kHz mono via AVAudioConverter.
    static func resample(_ mono: [Float], from inputRate: Int) throws -> [Float] {
        guard inputRate != sampleRate else { return mono }
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(inputRate), channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(mono.count)),
              let converter = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw NSError(domain: "SwiftWhisperAlign.MMS", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: "Could not configure the resampler."])
        }
        mono.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        inBuf.frameLength = AVAudioFrameCount(mono.count)
        let outCapacity = AVAudioFrameCount(Double(mono.count) * Double(sampleRate) / Double(inputRate)) + 256
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCapacity) else {
            throw NSError(domain: "SwiftWhisperAlign.MMS", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate the resample buffer."])
        }
        var supplied = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return inBuf
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }

    // Log-probabilities for the whole 16 kHz signal.
    static func logProbs(
        model: MLModel, audio: [Float],
        cancellationCheck: (@Sendable () -> Bool)?,
        onProgress: (@Sendable (Double) -> Void)?
    ) throws -> Matrix {
        let total = Double(audio.count) / Double(sampleRate)
        var rows: [Float] = []
        var frames = 0
        var frameSec = windowSec / 1599.0
        var t = 0.0
        while t < total {
            if cancellationCheck?() == true { throw CancellationError() }
            let a = max(0, t - overlapSec)
            let window = try MLMultiArray(shape: [1, NSNumber(value: windowSamples)], dataType: .float32)
            let p = window.dataPointer.bindMemory(to: Float.self, capacity: windowSamples)
            let start = Int(a * Double(sampleRate))
            let available = max(0, min(windowSamples, audio.count - start))
            if available > 0 {
                audio.withUnsafeBufferPointer { p.update(from: $0.baseAddress! + start, count: available) }
            }
            if available < windowSamples { (p + available).update(repeating: 0, count: windowSamples - available) }

            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": window]))
            guard let lp = out.featureValue(for: "logprobs")?.multiArrayValue else {
                throw NSError(domain: "SwiftWhisperAlign.MMS", code: 43,
                              userInfo: [NSLocalizedDescriptionKey: "Aligner model output missing."])
            }
            let F = lp.shape[1].intValue
            frameSec = windowSec / Double(F)
            let lead = Int(((t - a) / frameSec).rounded())
            let keep = min(Int((min(windowSec - (t - a), total - t) / frameSec).rounded()), F - lead)
            guard keep > 0 else { break }
            // The fp16 export hands back a Float16 array on device; convert rather than
            // reinterpret the buffer.
            let scalars = MLShapedArray<Float>(converting: lp).scalars
            rows.append(contentsOf: scalars[(lead * classes)..<((lead + keep) * classes)])
            frames += keep
            t += Double(keep) * frameSec
            onProgress?(min(1, t / total))
        }
        return Matrix(frames: frames, frameSec: frameSec, values: rows)
    }
}
