import Foundation

// One row in a conjugation paradigm card — the Japanese surface form and its English label.
struct ConjugationRow: Hashable, Sendable {
    // The English label for this row: the paradigm name (e.g. "Plain") for the first row,
    // or "Negative", "Past", "Negative past" for the remaining rows.
    let label: String
    // The conjugated Japanese surface form.
    let surface: String
}

// One paradigm card shown in ConjugationSheetView — e.g. "Plain" with rows for
// plain / negative / past / negative past forms.
struct ConjugationGroup: Identifiable, Sendable {
    // The paradigm name shown as the card title — e.g. "Plain", "Polite", "Progressive".
    let name: String
    // Ordered rows for this paradigm. First row label matches `name`.
    let rows: [ConjugationRow]

    var id: String { name }
}
