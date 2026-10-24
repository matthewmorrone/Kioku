import Foundation

// The word detail page the Read tab is presenting over the note: the word, the reading the lookup
// sheet showed for it, and the lookup's pre-computed sublattice paths.
struct ReadWordDetailTarget: Identifiable {
    let id = UUID()
    let word: SavedWord
    let reading: String?
    let sublatticePaths: [[String]]
}
