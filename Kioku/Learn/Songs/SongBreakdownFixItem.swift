import Foundation

// One row of the Breakdown's fix list: a suggested fix with the line it belongs to.
struct SongBreakdownFixItem: Identifiable, Equatable {
    let lineIndex: Int
    let lineText: String
    let fix: SongLineFix

    // Unique within a breakdown: a line never holds the same fix twice (SongBreakdownParser).
    var id: String { "\(lineIndex)|\(fix.kind.rawValue)|\(fix.original)|\(fix.replacement)" }
}
