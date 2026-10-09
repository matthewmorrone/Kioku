import Foundation

// One parsed row from a CSV/delimited import.
// Tracks user-provided values separately from dictionary-enriched values so
// the UI can distinguish what the user supplied vs what was inferred.
// `nonisolated` so the CSV import's `Task.detached` resolution loop can read the row's
// computed properties (finalSurface, finalKana, …) without crossing actor boundaries.
nonisolated struct CSVImportItem: Identifiable, Hashable {
    let id: UUID
    let lineNumber: Int

    var providedSurface: String?
    var providedKana: String?
    var providedMeaning: String?
    var providedNote: String?
    // Curriculum grouping columns (e.g. a textbook's chapter/volume)
    // — used only when the "By chapter" list mode routes each row to its own auto-created list.
    var providedChapter: String?
    var providedVolume: String?

    var computedSurface: String?
    var computedKana: String?
    var computedMeaning: String?

    // Resolves the best available surface form, preferring user-provided over dictionary-enriched.
    var finalSurface: String? { CSVImport.trim(providedSurface ?? computedSurface) }

    // Resolves the best available kana reading.
    var finalKana: String? { CSVImport.trim(providedKana ?? computedKana) }

    // Resolves the best available English meaning.
    var finalMeaning: String? { CSVImport.trim(providedMeaning ?? computedMeaning) }

    // Returns the personal note if non-empty.
    var finalNote: String? { CSVImport.trim(providedNote) }

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
        providedNote: String?,
        providedChapter: String? = nil,
        providedVolume: String? = nil
    ) {
        self.id = id
        self.lineNumber = lineNumber
        self.providedSurface = providedSurface
        self.providedKana = providedKana
        self.providedMeaning = providedMeaning
        self.providedNote = providedNote
        self.providedChapter = providedChapter
        self.providedVolume = providedVolume
    }

    // Resolves the chapter grouping key, e.g. "Vol 1 Ch 7" — combines volume + chapter (not
    // chapter alone) because a textbook's chapter numbers commonly restart or overlap across
    // volumes, so "Chapter 7" alone would silently merge two distinct chapters.
    var chapterGroupKey: String? {
        let chapter = CSVImport.trim(providedChapter)
        let volume = CSVImport.trim(providedVolume)
        switch (volume, chapter) {
        case (nil, nil): return nil
        case (let v?, nil): return "Vol \(v)"
        case (nil, let c?): return "Ch \(c)"
        case (let v?, let c?): return "Vol \(v) Ch \(c)"
        }
    }
}
