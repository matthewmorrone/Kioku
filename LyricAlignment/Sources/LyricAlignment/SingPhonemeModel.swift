// SingPhonemeModel.swift
//
// The short-window export of the HuBERT phoneme aligner (HubertPhonemeSing.mlmodelc: same model,
// labels and output as the alignment export, but a fixed 4 s input) that Sing mode runs every
// fraction of a second over the latest stretch of the singer's microphone audio.
// Sideloaded into the app's Documents folder for now; no download store yet.

import CoreML
import Foundation

public final class SingPhonemeModel: @unchecked Sendable {
    public static let windowSec = 4.0
    public static let windowSamples = 64_000
    public static let classes = CTCEmissions.classes
    public static let modelDirName = "HubertPhonemeSing.mlmodelc"

    private let model: MLModel
    // MLModel predictions are not safe to run concurrently on one instance.
    private let lock = NSLock()

    // Where the sideloaded model lives: Documents/HubertPhonemeSing.mlmodelc.
    public static var sideloadedURL: URL {
        URL.documentsDirectory.appendingPathComponent(modelDirName, isDirectory: true)
    }

    // Loads the compiled model; CPU only, as the alignment export runs (see CTCEmissions.loadModel).
    public init(url: URL = SingPhonemeModel.sideloadedURL) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: url, configuration: cfg)
    }

    // Row-major [frames × classes] log-probabilities for exactly `windowSamples` of 16 kHz mono
    // (shorter input is zero-padded at the front, so the newest audio stays at the window's end).
    // Returns the matrix and the duration of one frame.
    public func logProbs(window samples: [Float]) throws -> (values: [Float], frames: Int, frameSec: Double) {
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        let p = input.dataPointer.bindMemory(to: Float.self, capacity: Self.windowSamples)
        let count = min(samples.count, Self.windowSamples)
        let pad = Self.windowSamples - count
        if pad > 0 { p.update(repeating: 0, count: pad) }
        samples.withUnsafeBufferPointer { (p + pad).update(from: $0.baseAddress! + (samples.count - count), count: count) }

        lock.lock(); defer { lock.unlock() }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
        guard let lp = out.featureValue(for: "logprobs")?.multiArrayValue else {
            throw NSError(domain: "LyricAlignment.Sing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sing model output missing."])
        }
        let frames = lp.shape[1].intValue
        // The fp16 export hands back a Float16 array on device; convert rather than reinterpret.
        return (MLShapedArray<Float>(converting: lp).scalars, frames, Self.windowSec / Double(frames))
    }
}
