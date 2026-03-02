import SwiftUI
import Combine

final class NotesStore: ObservableObject {
    @Published var notes: [Note] {
        didSet { save() }
    }

    private let storageKey = "kioku.notes.v1"

    init() {
        notes = NotesStore.readNotes(for: storageKey)
    }

    func reload() {
        notes = NotesStore.readNotes(for: storageKey)
    }

    func addNote() {
        notes.insert(Note(), at: 0)
    }

    func addNote(title: String, content: String) {
        notes.insert(Note(title: title, content: content), at: 0)
    }

    @discardableResult
    func upsertNote(id: UUID?, title: String, content: String) -> UUID {
        if let id, let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index].title = title
            notes[index].content = content
            return id
        }

        let newNote = Note(title: title, content: content)
        notes.insert(newNote, at: 0)
        return newNote.id
    }

    func moveNotes(from source: IndexSet, to destination: Int) {
        notes.move(fromOffsets: source, toOffset: destination)
    }

    func deleteNotes(at offsets: IndexSet) {
        notes.remove(atOffsets: offsets)
    }

    func deleteNotes(ids: Set<UUID>) {
        notes.removeAll { ids.contains($0.id) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func readNotes(for key: String) -> [Note] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([Note].self, from: data)
        else {
            return []
        }

        return decoded
    }
}
