import Foundation

// Turns items sent from the share extension into notes. Runs when the app opens or returns to the
// foreground; the app is the only writer of the notes store, the extension just leaves files in the
// App Group inbox.
@MainActor
enum SharedInboxImporter {
    // Builds the note for one shared item. Text is kept as is; a link is fetched and converted to
    // plain text, and if that fails the link itself becomes the note so nothing the user shared is
    // lost.
    static func note(for item: SharedInboxItem, fetchText: (String) async throws -> String) async -> Note? {
        if let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false {
            return Note(title: title(for: item, fallback: text), content: text)
        }
        guard let urlString = item.url?.trimmingCharacters(in: .whitespacesAndNewlines), urlString.isEmpty == false else {
            return nil
        }
        let host = URL(string: urlString)?.host ?? urlString
        do {
            let text = try await fetchText(urlString)
            return Note(title: item.title.isEmpty ? host : item.title, content: text)
        } catch {
            AppLog.error(.notesImport, "[SharedInbox] could not fetch \(urlString), keeping the link: \(error.localizedDescription)")
            return Note(title: item.title.isEmpty ? host : item.title, content: urlString)
        }
    }

    // Drains the inbox into the notes store, newest share at the top. Returns how many notes were added.
    @discardableResult
    static func importPending(into store: NotesStore, directory: URL? = SharedInbox.defaultDirectory()) async -> Int {
        guard let directory else { return 0 }
        let drained = SharedInbox.drain(from: directory)
        for problem in drained.problems { AppLog.error(.storage, "[SharedInbox] \(problem)") }
        var added = 0
        for item in drained.items {
            guard let note = await note(for: item, fetchText: URLTextImporter.extractText(from:)) else { continue }
            store.addNote(note)
            added += 1
        }
        return added
    }

    // The note title: what the user typed in the share sheet, else the first line of the text.
    private static func title(for item: SharedInboxItem, fallback text: String) -> String {
        let typed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty == false { return typed }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(firstLine.prefix(30))
    }
}
