import SwiftUI
import Combine

final class NotesStore: ObservableObject {
    @Published var notes: [Note] {
        didSet { save() }
    }

    private let storageKey = "kioku.notes.v1"

    // Loads persisted notes so the in-memory store starts from disk state.
    init() {
        notes = NotesStore.readNotes(for: storageKey)
    }

    // Reloads notes from storage to reflect external updates.
    func reload() {
        notes = NotesStore.readNotes(for: storageKey)
    }

    // Inserts a new empty note at the top of the list.
    func addNote() {
        notes.insert(Note(), at: 0)
    }

    // Reorders notes using list move semantics.
    func moveNotes(from source: IndexSet, to destination: Int) {
        notes.move(fromOffsets: source, toOffset: destination)
    }

    // Deletes notes at the provided list offsets.
    func deleteNotes(at offsets: IndexSet) {
        notes.remove(atOffsets: offsets)
    }

    // Deletes notes whose identifiers are currently selected.
    func deleteNotes(ids: Set<UUID>) {
        notes.removeAll { ids.contains($0.id) }
    }

    // Persists the current notes array into user defaults.
    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    // Reads and decodes notes for the given storage key.
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
