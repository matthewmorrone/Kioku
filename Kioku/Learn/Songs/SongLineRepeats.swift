import Foundation

// Collapses a song's back-to-back identical lines (a chorus singing "Sailor Moon" four times) into
// one card carrying a repeat count, so the list shows "Sailor Moon ×4" instead of four copies.
enum SongLineRepeats {
    // The items to show, each with how many consecutive lines it stands for. Only settled lines fold:
    // a line still streaming or being played keeps its own card so its ring and spinner stay put.
    static func collapse(_ items: [SongLineDisplayItem]) -> [(item: SongLineDisplayItem, count: Int)] {
        var result: [(item: SongLineDisplayItem, count: Int)] = []
        for item in items {
            let text = item.line.original.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = result.last,
               text.isEmpty == false,
               item.phase == .ready, last.item.phase == .ready,
               last.item.line.original.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                result[result.count - 1].count += 1
            } else {
                result.append((item, 1))
            }
        }
        return result
    }
}
