import CoreML
import Foundation

// The boundary model (SegmentBoundaryNet.mlpackage beside this file, trained by
// scripts/segmentation-eval/boundary): P(cut) at every gap between two characters, from the
// characters around it and the lattice's evidence there. The path search adds its verdict as
// BoundaryCosts, so it only decides between paths the lattice already priced close. It runs on the
// CPU in float32 and its costs are rounded to whole centi-nats, so every device segments alike.
final class BoundaryModel: @unchecked Sendable {
    private let model: MLModel
    // Character → embedding index, as trained; 1 is the shared slot for characters it never saw.
    private let vocabulary: [String: Int32]
    // MLModel prediction is serialised: the segmenter can be called from more than one task at once.
    private let lock = NSLock()

    // Wraps a loaded model and its character table.
    init(model: MLModel, vocabulary: [String: Int32]) {
        self.model = model
        self.vocabulary = vocabulary
    }

    // The model shipped with the app: compiled into the bundle on device, or compiled from the
    // package beside this file when the code runs outside an app bundle (unit tests, segcli). Nil,
    // logged, when neither loads — segmentation then runs on word and transition costs alone.
    static func bundled() -> BoundaryModel? {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        do {
            let model: MLModel
            if let compiled = Bundle.main.url(forResource: "SegmentBoundaryNet", withExtension: "mlmodelc") {
                model = try MLModel(contentsOf: compiled, configuration: configuration)
            } else {
                let package = here.appendingPathComponent("SegmentBoundaryNet.mlpackage")
                model = try MLModel(contentsOf: try MLModel.compileModel(at: package), configuration: configuration)
            }
            let vocabularyURL = Bundle.main.url(forResource: "SegmentBoundaryVocab", withExtension: "json")
                ?? here.appendingPathComponent("SegmentBoundaryVocab.json")
            let vocabulary = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: vocabularyURL))
            return BoundaryModel(model: model, vocabulary: vocabulary)
        } catch {
            AppLog.error(.segmentation, "Boundary model failed to load: \(error)")
            return nil
        }
    }

    // P(cut) per gap 1..<n of text, given its lattice and the path the search chose without the
    // model (the model reads that path's cuts as an input). Nil, logged, if prediction fails.
    func cutProbabilities(text: String, lattice: [LatticeEdge], path: [LatticeEdge]) -> [Double]? {
        let characters = Array(text)
        let n = characters.count
        guard n > 1 else { return [] }
        let gapFeatures = BoundaryFeatures.gapFeatures(lattice: lattice, in: text)
        let cuts = BoundaryFeatures.pathCuts(path, in: text)
        do {
            let chars = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
            let scripts = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
            let gaps = try MLMultiArray(shape: [1, NSNumber(value: n - 1), NSNumber(value: Self.gapInputCount)], dataType: .float32)
            for (i, character) in characters.enumerated() {
                chars[i] = NSNumber(value: vocabulary[String(character)] ?? 1)
                scripts[i] = NSNumber(value: BoundaryFeatures.scriptClass(character))
            }
            for gap in 0..<(n - 1) {
                for (k, value) in Self.encodedGap(gapFeatures[gap], cut: cuts[gap]).enumerated() {
                    gaps[gap * Self.gapInputCount + k] = NSNumber(value: value)
                }
            }
            let input = try MLDictionaryFeatureProvider(dictionary: ["chars": chars, "scripts": scripts, "gaps": gaps])
            lock.lock()
            defer { lock.unlock() }
            let output = try model.prediction(from: input)
            guard let cut = output.featureValue(for: "cut")?.multiArrayValue, cut.count == n - 1 else {
                AppLog.error(.segmentation, "Boundary model returned no usable output for \(n) characters")
                return nil
            }
            return (0..<(n - 1)).map { cut[$0].doubleValue }
        } catch {
            AppLog.error(.segmentation, "Boundary model prediction failed: \(error)")
            return nil
        }
    }

    // Width of one encoded gap (scripts/segmentation-eval/boundary/model.py GAP_INPUTS).
    static let gapInputCount = 15

    // One gap's network input, exactly as model.py encode_gap builds it in training: edge counts as
    // ln(1 + n), each node cost in tens of nats with a has-none flag, then the chosen path's cut.
    static func encodedGap(_ features: [Int], cut: Int) -> [Float] {
        var out = features.prefix(10).map { Float(log1p(Double($0))) }
        for cost in features[10...11] {
            out += cost < 0 ? [0, 1] : [Float(Double(cost) / 1000), 0]
        }
        out.append(Float(cut))
        return out
    }
}
