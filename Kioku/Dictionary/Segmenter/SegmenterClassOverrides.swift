import Foundation

// Loads segmenter-class-overrides.tsv: kanji spellings the transition table classes by the first
// sense of their most common entry instead of the union of every entry (間 → noun, not the
// conjunction "while"). Built by scripts/calibration/segmenter_class_overrides.py; never edit it by
// hand. The transition table and the reading contexts are counted with these classes, so the three
// files are regenerated together.
nonisolated enum SegmenterClassOverrides {
    // The bundled overrides as surface → POS bits: from the app bundle on device, or from the source
    // tree when the code runs outside one (unit tests, the eval harness). Empty when the file is
    // missing or unreadable, which classes every word by its union bits as before.
    static func bundled() -> [String: UInt64] {
        let besideThisFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("segmenter-class-overrides.tsv")
        let candidates = [Bundle.main.url(forResource: "segmenter-class-overrides", withExtension: "tsv"), besideThisFile]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            do {
                return parse(try String(contentsOf: url, encoding: .utf8))
            } catch {
                AppLog.error(.segmentation, "segmenter-class-overrides.tsv at \(url.path) unreadable: \(error)")
            }
        }
        AppLog.error(.segmentation, "segmenter-class-overrides.tsv not loaded; words class by their union POS")
        return [:]
    }

    // Parses "surface <tab> pos codes" rows into POS bits, skipping malformed ones loudly.
    static func parse(_ text: String) -> [String: UInt64] {
        var bitsBySurface: [String: UInt64] = [:]
        for row in text.split(separator: "\n") {
            let fields = row.split(separator: "\t")
            guard fields.count == 2 else {
                AppLog.error(.segmentation, "segmenter-class-overrides.tsv: skipping malformed row \(row)")
                continue
            }
            bitsBySurface[String(fields[0])] = PartOfSpeech.bits(from: String(fields[1]))
        }
        return bitsBySurface
    }
}
