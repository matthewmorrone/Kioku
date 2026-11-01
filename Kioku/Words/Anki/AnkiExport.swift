import CoreTransferable
import Foundation
import UniformTypeIdentifiers

// A set of saved words offered to the share sheet as an Anki-importable text file. The file is
// built when the user picks a destination, off the main actor, so opening the menu stays instant.
nonisolated struct AnkiExport: Transferable {
    let words: [SavedWord]
    let store: DictionaryStore
    // List names by id, for each word's tags.
    let listNamesByID: [UUID: String]

    static let fileName = "Kioku Anki Export.txt"
    private static let fetchBatchSize = 200

    // Offers the words as a plain-text file named for the export.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            SentTransferredFile(try export.writeFile())
        }
    }

    // The rows for every word, with entries fetched in batches rather than one query per word.
    func rows() -> [AnkiRow] {
        var contentByEntryID: [Int64: DictionaryEntry] = [:]
        let entryIDs = Array(Set(words.map(\.canonicalEntryID)))
        for start in stride(from: 0, to: entryIDs.count, by: Self.fetchBatchSize) {
            let batch = Array(entryIDs[start..<min(start + Self.fetchBatchSize, entryIDs.count)])
            do {
                for entry in try store.lookupEntries(entryIDs: batch) { contentByEntryID[entry.entryId] = entry }
            } catch {
                AppLog.error(.dictionary, "[AnkiExport] batch lookup failed: \(error)")
            }
        }
        return words.map { word in
            let content = contentByEntryID[word.canonicalEntryID].map {
                WordCardContentResolver.resolve(word: word, entry: $0, store: store)
            }
            let listNames = word.wordListIDs.compactMap { listNamesByID[$0] }
            return AnkiTSVBuilder.row(for: word, content: content, listNames: listNames)
        }
    }

    // Writes the file into a fresh temporary folder and returns its URL.
    func writeFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName)
        try AnkiTSVBuilder.build(rows: rows()).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
