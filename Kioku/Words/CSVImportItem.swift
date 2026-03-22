import Foundation

// One parsed row from a CSV/delimited import.
// Tracks user-provided values separately from dictionary-enriched values so
// the UI can distinguish what the user supplied vs what was inferred.
struct CSVImportItem: Identifiable, Hashable {
    let id: UUID
    let lineNumber: Int

    var providedSurface: String?
    var providedKana: String?
    var providedMeaning: String?
    var providedNote: String?

    var computedSurface: String?
    var computedKana: String?
    var computedMeaning: String?

    // Resolves the best available surface form, preferring user-provided over dictionary-enriched.
    var finalSurface: String? { trimmed(providedSurface ?? computedSurface) }

    // Resolves the best available kana reading.
    var finalKana: String? { trimmed(providedKana ?? computedKana) }

    // Resolves the best available English meaning.
    var finalMeaning: String? { trimmed(providedMeaning ?? computedMeaning) }

    // Returns the personal note if non-empty.
    var finalNote: String? { trimmed(providedNote) }

    // Importable when both a surface and a meaning can be resolved.
    var isImportable: Bool {
        finalSurface?.isEmpty == false && finalMeaning?.isEmpty == false
    }

    init(
        id: UUID = UUID(),
        lineNumber: Int,
        providedSurface: String?,
        providedKana: String?,
        providedMeaning: String?,
        providedNote: String?
    ) {
        self.id = id
        self.lineNumber = lineNumber
        self.providedSurface = providedSurface
        self.providedKana = providedKana
        self.providedMeaning = providedMeaning
        self.providedNote = providedNote
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
