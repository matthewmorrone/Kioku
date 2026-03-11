import SwiftUI
import Combine

@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [Note] {
        didSet { save() }
    }

    private let storageKey = "kioku.notes.v1"
    private let persistenceQueue = DispatchQueue(label: "Kioku.NotesStore.persistence", qos: .utility)
    private var pendingReadEditorPersistWorkItem: DispatchWorkItem?

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

    // Returns the latest in-memory note for a known identifier.
    func note(withID id: UUID) -> Note? {
        notes.first(where: { $0.id == id })
    }

    // Inserts or updates one note in memory so editing does not re-read the full store.
    func upsertNote(id: UUID?, title: String, content: String, tokenRanges: [TokenRange]?) -> UUID {
        if let id, let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index].title = title
            notes[index].content = content
            notes[index].tokenRanges = tokenRanges
            return id
        }

        let newNote = Note(title: title, content: content, tokenRanges: tokenRanges)
        notes.insert(newNote, at: 0)
        return newNote.id
    }

    // Schedules a read-screen edit to persist directly to storage without publishing every intermediate change.
    func scheduleReadEditorPersist(id: UUID?, title: String, content: String, tokenRanges: [TokenRange]?) -> UUID {
        let resolvedID = id ?? UUID()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteToPersist = Note(id: resolvedID, title: trimmedTitle, content: content, tokenRanges: tokenRanges)

        pendingReadEditorPersistWorkItem?.cancel()

        let storageKey = storageKey
        let workItem = DispatchWorkItem {
            var notes = Self.readNotes(for: storageKey)
            if let index = notes.firstIndex(where: { $0.id == resolvedID }) {
                notes[index] = noteToPersist
            } else {
                notes.insert(noteToPersist, at: 0)
            }

            guard let encoded = try? JSONEncoder().encode(notes) else { return }
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }

        pendingReadEditorPersistWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + 0.2, execute: workItem)
        return resolvedID
    }

    // Persists the current notes array into user defaults immediately.
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
