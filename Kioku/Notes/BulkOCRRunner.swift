import Foundation

// Runs OCR over several photos and reports one result per photo, in the order they were picked, so
// one unreadable photo costs only itself. Each photo with text becomes its own note, as a single
// photo import does.
nonisolated enum BulkOCRRunner {
    // Recognizes each input in turn (one at a time, since a recognition request holds a full image
    // in memory). `recognize` is injected so tests don't need Vision.
    static func run(inputs: [BulkOCRInput], recognize: (Data) throws -> String) -> [BulkOCROutcome] {
        inputs.map { input in
            switch input {
            case .unreadable(let reason):
                return .failed(reason)
            case .image(let data):
                do {
                    let text = try recognize(data).trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? .noText : .recognized(text)
                } catch {
                    AppLog.error(.notesImport, "OCR: bulk recognition failed — \(error.localizedDescription)")
                    return .failed(error.localizedDescription)
                }
            }
        }
    }

    // One note per photo that had text, titled "Photo n" by its position in the selection so the
    // notes stay distinguishable in the list.
    @MainActor
    static func notes(from outcomes: [BulkOCROutcome]) -> [Note] {
        outcomes.enumerated().compactMap { offset, outcome in
            guard case .recognized(let text) = outcome else { return nil }
            return Note(title: "Photo \(offset + 1)", content: text)
        }
    }

    // A plain-language per-photo report for the alert shown when the import finishes.
    static func summary(of outcomes: [BulkOCROutcome]) -> String {
        let recognized = outcomes.filter { if case .recognized = $0 { return true } else { return false } }.count
        var lines = ["Read \(recognized) of \(outcomes.count) photos into notes."]
        for (offset, outcome) in outcomes.enumerated() {
            switch outcome {
            case .recognized: continue
            case .noText: lines.append("Photo \(offset + 1): no text found.")
            case .failed(let reason): lines.append("Photo \(offset + 1): \(reason)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
