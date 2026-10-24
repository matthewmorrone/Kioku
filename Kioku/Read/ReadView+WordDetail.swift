import Foundation

extension ReadView {
    // Opens the word's detail page over the note, as a sheet from this tab: no hop to the Words
    // tab (which flashed before the sheet rose and again on the way back). Recorded to history like
    // any other lookup.
    func presentWordDetail(entryID: Int64, surface: String, reading: String?, sublatticePaths: [[String]]) {
        guard let word = wordsStore.detailWord(entryID: entryID, surfaceHint: surface) else { return }
        historyStore.record(canonicalEntryID: word.canonicalEntryID, surface: word.surface)
        readSheets.wordDetail = ReadWordDetailTarget(word: word, reading: reading, sublatticePaths: sublatticePaths)
    }
}
